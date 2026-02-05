from flask import Flask, request, jsonify
import os, json, datetime, subprocess, requests, time, re
from dotenv import load_dotenv
import google.generativeai as genai
from typing import Optional, Tuple

# ===============================
# 初期設定
# ===============================
app = Flask(__name__)
load_dotenv()

GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
genai.configure(api_key=os.getenv("GEMINI_API_KEY"))
BASE_DIR = "results"
os.makedirs(BASE_DIR, exist_ok=True)

PROM_URL = os.getenv("PROM_URL", "http://c0a22169-monitoring:30900")
MAX_ATTEMPTS = int(os.getenv("MAX_ATTEMPTS", "5"))
SLEEP_AFTER_EXEC = int(os.getenv("SLEEP_AFTER_EXEC", "30"))
RECHECK_ATTEMPTS = int(os.getenv("RECHECK_ATTEMPTS", "3"))

PROCESSING_CACHE = set()

# ===============================
# ユーティリティ関数
# ===============================
def ts_now(fmt="%Y%m%d_%H%M%S"): 
    return datetime.datetime.now().strftime(fmt)

def save_json(data, prefix):
    dir_path = os.path.join(BASE_DIR, datetime.datetime.now().strftime("%Y%m%d"))
    os.makedirs(dir_path, exist_ok=True)
    path = os.path.join(dir_path, f"{prefix}_{ts_now()}.json")
    with open(path, "w") as f: json.dump(data, f, indent=2)
    print(f"📁 JSON保存: {path}")
    return path

def save_prompt(prompt: str, prefix: str) -> str:
    dir_path = os.path.join(BASE_DIR, datetime.datetime.now().strftime("%Y%m%d"), "prompts")
    os.makedirs(dir_path, exist_ok=True)
    path = os.path.join(dir_path, f"{prefix}_{ts_now()}.txt")
    with open(path, "w") as f: f.write(prompt)
    print(f"💾 プロンプト保存: {path}")
    return path

def save_script(script_text: str, filename: str) -> str:
    day_dir = os.path.join(BASE_DIR, datetime.datetime.now().strftime("%Y%m%d"), "generated_scripts")
    os.makedirs(day_dir, exist_ok=True)
    path = os.path.join(day_dir, filename)
    with open(path, "w") as f: f.write(script_text)
    subprocess.run(["chmod", "+x", path])
    print(f"✅ スクリプト生成: {path}")
    return path

def execute_script_and_save(script_path: str, prefix: str) -> Tuple[str, str]:
    result_dir = os.path.join(BASE_DIR, datetime.datetime.now().strftime("%Y%m%d"), "exec_results")
    os.makedirs(result_dir, exist_ok=True)
    out_path = os.path.join(result_dir, f"{prefix}_stdout_{ts_now()}.log")
    err_path = os.path.join(result_dir, f"{prefix}_stderr_{ts_now()}.log")
    subprocess.run(["bash", script_path], stdout=open(out_path, "w"), stderr=open(err_path, "w"))
    print(f"📝 実行ログ保存: {out_path}, {err_path}")
    return out_path, err_path

def get_prometheus_metric_instant(query: str, retries=3, delay=2) -> Optional[float]:
    for i in range(retries):
        try:
            resp = requests.get(f"{PROM_URL}/api/v1/query", params={"query": query}, timeout=6)
            data = resp.json()
            if data.get("status") == "success" and data["data"]["result"]:
                return float(data["data"]["result"][0]["value"][1])
        except Exception as e:
            print(f"⚠️ Prometheus取得エラー ({i+1}/{retries}):", e)
        time.sleep(delay)
    return None

def collect_environment_info(namespace: str) -> str:
    cmds = [
        f"kubectl get pods -n {namespace} -o wide",
        f"kubectl top pods -n {namespace} || true",
        "df -h", "free -h"
    ]
    results = []
    for cmd in cmds:
        try: results.append(f"$ {cmd}\n{subprocess.check_output(cmd, shell=True, text=True, timeout=12)}\n")
        except Exception as e: results.append(f"$ {cmd}\nError: {e}\n")
    return "\n".join(results)

def extract_script_from_response(text: str) -> str:
    m = re.search(r"```(?:bash|sh)?\s*\n(.*?)```", text, re.DOTALL)
    if m: return m.group(1).strip()
    return "#!/bin/bash\n" + text.strip()

def generate_script_with_gemini(prompt: str, outfile_name: str) -> str:
    print("🧠 スクリプト生成中...")
    model = genai.GenerativeModel(GEMINI_MODEL)
    response = model.generate_content(prompt)
    script = extract_script_from_response(response.text)
    return save_script(script, outfile_name)

def recheck_metric_stability(promql: str, attempts: int = RECHECK_ATTEMPTS, wait_seconds: int = SLEEP_AFTER_EXEC) -> Optional[float]:
    vals = []
    for i in range(attempts):
        v = get_prometheus_metric_instant(promql)
        print(f"🔁 recheck {i+1}/{attempts} -> {v}")
        if v is not None: vals.append(v)
        time.sleep(wait_seconds)
    if not vals: return None
    vals_sorted = sorted(vals)
    mid = len(vals_sorted)//2
    return vals_sorted[mid] if len(vals_sorted)%2==1 else (vals_sorted[mid-1]+vals_sorted[mid])/2

# ===============================
# メインハンドラ
# ===============================
@app.route("/alert", methods=["POST"])
def handle_alert():
    alert = request.json
    if not alert: return jsonify({"error": "no json"}), 400
    save_json(alert, "alert")

    fingerprint = (alert.get("alerts") or [{}])[0].get("fingerprint", f"nofp_{ts_now()}")
    if fingerprint in PROCESSING_CACHE:
        print("⚠️ 同一アラートを既に処理済み（ランタイム内）")
        return jsonify({"status":"skipped"}), 200
    PROCESSING_CACHE.add(fingerprint)

    # --- 固定 PromQL を使用 ---
    promql = '(kubelet_volume_stats_used_bytes{instance=~"c0a22169-monitoring|c0a22169-monitoring2"} / kubelet_volume_stats_capacity_bytes{instance=~"c0a22169-monitoring|c0a22169-monitoring2"}) * 100'
    last_after = None
    attempt_details = []
    success = False

    for attempt in range(1, MAX_ATTEMPTS+1):
        print(f"\n=== 🧩 試行 {attempt}/{MAX_ATTEMPTS} ===")
        before = get_prometheus_metric_instant(promql)
        print(f"📊 before={before}")

        env_info = collect_environment_info("monitoring")

        # 動的プロンプト生成
        prompt = f"""
# Alert情報
{alert}

# 環境情報
{env_info}

# 現状PVC使用率
before={before}
threshold={os.getenv('THRESHOLD', '90.0')}

# 前回試行結果
last_after={last_after if last_after is not None else 'なし'}

# 要求
アラートを対処することができる bash スクリプトを生成してください。
- 実行可能な kubectl コマンドやシステム設定変更を使用
- 前回試行では改善が見られませんでした
- 出力は必ず ```bash ``` で囲み、スクリプトのみを返してください
"""
        save_prompt(prompt, f"attempt_{attempt}")
        script_filename = f"fix_{attempt}_{ts_now()}.sh"
        try:
            script_path = generate_script_with_gemini(prompt, script_filename)
        except Exception as e:
            print("🚨 Gemini生成エラー:", e)
            continue

        stdout_path, stderr_path = execute_script_and_save(script_path, f"fix_{attempt}")
        try:
            last_stdout = open(stdout_path,"r").read()
            last_stderr = open(stderr_path,"r").read()
        except:
            last_stdout = last_stderr = ""

        after = recheck_metric_stability(promql)
        print(f"📈 after={after}")
        last_after = after

        attempt_details.append({"attempt":attempt,"before":before,"after":after,"script":script_path})

        if after is not None and float(after) < float(os.getenv("THRESHOLD", "90.0")):
            print("✅ しきい値を下回りました")
            success = True
            break
        else:
            print("⚠️ 改善なし、次の試行へ")

    result = {"fingerprint":fingerprint,"metric_promql":promql,"before":before,"after":last_after,"success":success,"attempts":attempt_details}
    save_json(result,f"result_{ts_now()}")

    PROCESSING_CACHE.discard(fingerprint)
    return jsonify(result), 200

# ===============================
# 実行
# ===============================
if __name__ == "__main__":
    key = os.getenv("GEMINI_API_KEY")
    print(f"✅ GEMINI_API_KEY OK (len={len(key)})" if key else "❌ GEMINI_API_KEY 未設定")
    print(f"✅ PROM_URL={PROM_URL}, MAX_ATTEMPTS={MAX_ATTEMPTS}, SLEEP_AFTER_EXEC={SLEEP_AFTER_EXEC}, RECHECK_ATTEMPTS={RECHECK_ATTEMPTS}")
    app.run(host="0.0.0.0", port=int(os.getenv("PORT","5000")), threaded=False)
