# Alert_AutoFix
## 概要
このFlaskアプリケーションは，Alertmanagerから送信されるアラートをJSON形式で受け取り，Gemini APIを用いて自動的に対処スクリプトを生成，評価，再生成するWebhookエンドポイントです． 生成されたスクリプトは実行後に結果を解析し，有効でない場合には再度プロンプトを修正してスクリプトを再生成します．

## 環境 
- OS： Ubuntu 24.04.2 LTS
- Python： 3.12.3
- Gemini： gemini-2.5-flash 

## Python ライブラリ： 
- flask
- os
- google.generativeai
- re
- requests
- dotenv

"" 主な構成ファイル
| ファイル名   | 内容 |
| ------------- | ------------- |
| gemini_alert.py  | Flaskアプリ本体  |
| requirements.txt  | 実行に必要なPythonパッケージ  |
| .env  | GEMINI_API_KEY などの環境変数用  |


## 動作の流れ 
1. Alertmanagerから/alertエンドポイントにJSON形式のアラートを受信
2. 受信したアラートをもとに，Gemini APIへプロンプトを送信
3. Geminiの応答からbashスクリプトを抽出し，fix_issue.shとして保存
4. 生成されたスクリプトを実行し，標準出力・エラー出力をログとして保存
5. メトリクスがしきい値を下回らない場合はプロンプトを再生成して再試行
6. 有効なスクリプトが得られるまで繰り返す

## 注意事項 
- Gemini APIの利用にはAPIキーの設定が必要です
  ```export GEMINI_APIKEY="your-api-key"```
- APIの利用には料金や使用制限が発生する場合があります
- gemini_alert.py内のURLやPod名など実際の環境に合わせて変更する箇所があります．
- 生成されるスクリプトは生成AIによって作成されるため必ず復旧できるわけではないです．内容は必ず確認してからの実行，プロンプトを追加するなどして対応してください．

## 使用例 
今回は以下のコマンドを実行して仮想環境で説明します． 
1. 仮想環境の作成と有効化
   ```
   $ python3 -m venv gemini c0a22169-mo1@c0a22169-monitoring:~/gemini_alert$ $ source gemini/bin/activate (gemini) c0a22169-mo1@c0a22169-monitoring:~/gemini_alert$
   ```
2. Gemini APIキー設定 $ export GEMINI_APIKEY="your-api-key" (gemini) c0a22169-mo1@c0a22169-monitoring:~/gemini_alert$

3. 3. Flaskアプリ起動 $ python3 gemini_alert.py ✅ GEMINI_API_KEY が設定されました（長さ: 39） * Serving Flask app 'gemini_alert' * Debug mode: on WARNING: This is a development server. Do not use it in a production deployment. Use a production WSGI server instead. * Running on all addresses (0.0.0.0) * Running on http://127.0.0.1:5000 * Running on http://192.168.100.78:5000 Press CTRL+C to quit * Restarting with stat ✅ GEMINI_API_KEY が設定されました（長さ: 39） * Debugger is active! * Debugger PIN: 128-429-581

4. 動作確認
今回はテストとして別のターミナルでcurlを実行し，動作の確認を行います．
```
$ curl -X POST http://localhost:5000/alert -H "Content-Type: application/json" -d '{
  "namespace": "redmine",
  "pod": "redmine-659869bc68-q7w4g",
  "metric": "container_memory_usage_bytes",
  "threshold": 85.0,
  "prometheus_url": "http://c0a22169-monitoring:30900/api/v1/query"
}'
```
curlを実行したら，以下のようにFlaskアプリを起動した結果の下に表示されます．
```
$ python3 gemini_alert2.py ✅ GEMINI_API_KEY が設定されました（長さ: 39） * Serving Flask app 'gemini_alert2' * Debug mode: on WARNING: This is a development server. Do not use it in a production deployment. Use a production WSGI server instead. * Running on all addresses (0.0.0.0) * Running on http://127.0.0.1:5000 * Running on http://192.168.100.78:5000 Press CTRL+C to quit * Restarting with stat ✅ GEMINI_API_KEY が設定されました（長さ: 39） * Debugger is active! * Debugger PIN: 128-429-581 📁 JSONを保存: results/20251102/alert_20251102_161114.json 🎯 対象メトリクス: (sum by (pod, namespace) (container_memory_usage_bytes{namespace='redmine', pod='redmine-659869bc68-q7w4g'})/ sum by (pod, namespace) (container_spec_memory_limit_bytes{namespace='redmine', pod='redmine-659869bc68-q7w4g'} > 0)) * 100 📊 しきい値: 85.0, 現状値(before): 96.14639282226562 WARNING: All log messages before absl::InitializeLog() is called are written to STDERR E0000 00:00:1762099874.308324 99503 alts_credentials.cc:93] ALTS creds ignored. Not running on GCP and untrusted ALTS is not enabled. ✅ スクリプト生成: results/generated_scripts/confirm.sh ✅ スクリプト生成: results/generated_scripts/fix_issue.sh
```
保存されたスクリプトやログは/resultsで確認できます． 
```
$ ls 20251102 exec_results generated_scripts (gemini) c0a22169-mo1@c0a22169-monitoring:~/gemini_alert/results$
```
  
## おわりに
本アプリは、Gemini API を活用してアラート対応の支援を行うツールです． 生成 AI に依存しているため、まだ完全な自動復旧はできません。 今後は、生成されたスクリプトを安全に自動実行する仕組みの実装が課題です。
