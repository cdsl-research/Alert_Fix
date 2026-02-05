#!/bin/bash

# このスクリプトは、Kubernetesクラスター内のRedmineコンテナのメモリリミットとリクエストを増やすことで、
# メモリ使用率が高いというアラートを解消することを目的としています。
# アラート情報から、Redmineコンテナのメモリ使用率が設定されたリミットの90%を超えていると判断されます。
# kubectl top podsの結果とアラートのトリガーが示す使用率の差を考慮し、
# 現在のリミット（またはデフォルトの200Mi）から50%増量し、かつ最低300Miに設定します。
# これにより、Redmineアプリケーションがより多くのメモリを利用できるようになり、アラートが解消されることが期待されます。

# Configuration
NAMESPACE="redmine"
DEPLOYMENT_NAME="redmine"
CONTAINER_NAME="redmine"

echo "Redmineコンテナのメモリリミットを増やすパッチを適用します..."

# コンテナの現在のメモリリミットとリクエストを取得します。
# 見つからない場合や空の場合は、計算用にデフォルト値を設定します。
CURRENT_MEM_LIMIT_STR=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="'$CONTAINER_NAME'")].resources.limits.memory}' 2>/dev/null)
CURRENT_MEM_REQUEST_STR=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="'$CONTAINER_NAME'")].resources.requests.memory}' 2>/dev/null)

# 計算用のデフォルトリミット (MiB単位)
DEFAULT_LIMIT_MIB=200

# メモリ文字列 (例: "200Mi", "1Gi") をMiB (浮動小数点数) に変換する関数
convert_to_mib() {
    local mem_str="$1"
    if [[ -z "$mem_str" ]]; then
        echo "$DEFAULT_LIMIT_MIB.0" # デフォルトの200.0 MiBを使用
        return
    fi

    # 数値部分と単位部分を抽出
    NUM_PART=$(echo "$mem_str" | sed -E 's/([0-9]+)([A-Za-z]*)/\1/')
    UNIT_PART=$(echo "$mem_str" | sed -E 's/([0-9]+)([A-Za-z]*)/\2/')

    case "$UNIT_PART" in
        "Mi"|"M") echo "${NUM_PART}.0" ;;
        "Gi"|"G") echo "scale=2; $NUM_PART * 1024" | bc ;;
        "Ki"|"K") echo "scale=2; $NUM_PART / 1024" | bc ;;
        "") echo "scale=2; $NUM_PART / (1024 * 1024)" | bc # 単位がない場合はバイトと仮定
        *) echo "${NUM_PART}.0" # 単位が認識できない場合のフォールバック、安全のためMiBとして扱う
    esac
}

CURRENT_MEM_LIMIT_MIB=$(convert_to_mib "$CURRENT_MEM_LIMIT_STR")
CURRENT_MEM_REQUEST_MIB=$(convert_to_mib "$CURRENT_MEM_REQUEST_STR")

echo "デプロイメント '$DEPLOYMENT_NAME' のコンテナ '$CONTAINER_NAME' の現在のメモリリミット: ${CURRENT_MEM_LIMIT_STR:-"設定なし、計算用には${DEFAULT_LIMIT_MIB}Miを仮定"}"
echo "デプロイメント '$DEPLOYMENT_NAME' のコンテナ '$CONTAINER_NAME' の現在のメモリリクエスト: ${CURRENT_MEM_REQUEST_STR:-"設定なし、計算用には${DEFAULT_LIMIT_MIB}Miを仮定"}"

# 新しいメモリリミットを計算します: 現在のリミットから50%増量します。
# 結果は整数にし、かつ最低でも300Miになるようにします。
# （kubectl top pods の 173Mi とアラートの 94% を考慮すると、現在のリミットは ~183Mi 程度の可能性があり、
# 50%増量で約275Mi。そのため、少なくとも300Miに設定することで確実に問題を解消することを目指します。）
NEW_MEM_LIMIT_MIB=$(echo "scale=0; ($CURRENT_MEM_LIMIT_MIB * 1.5) / 1" | bc)
if [[ $(echo "$NEW_MEM_LIMIT_MIB < 300" | bc -l) -eq 1 ]]; then
    NEW_MEM_LIMIT_MIB=300
fi

NEW_MEM_LIMIT="${NEW_MEM_LIMIT_MIB}Mi"
NEW_MEM_REQUEST="${NEW_MEM_LIMIT_MIB}Mi" # QoSをGuaranteedにするため、リクエストもリミットと同じ値に設定します

echo "コンテナ '$CONTAINER_NAME' の新しいメモリリミットを $NEW_MEM_LIMIT に設定します。"
echo "コンテナ '$CONTAINER_NAME' の新しいメモリリクエストを $NEW_MEM_REQUEST に設定します。"

# パッチYAMLを作成
# EOFヒアドキュメントを使用し、変数を展開できるようにします。
PATCH_YAML=$(cat <<EOF
spec:
  template:
    spec:
      containers:
      - name: $CONTAINER_NAME
        resources:
          limits:
            memory: $NEW_MEM_LIMIT
          requests:
            memory: $NEW_MEM_REQUEST
EOF
)

# パッチを適用
kubectl patch deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --patch "$PATCH_YAML"

if [ $? -eq 0 ]; then
    echo "デプロイメント '$DEPLOYMENT_NAME' のパッチ適用が成功しました。"
    echo "ロールアウトが完了するまで待機します..."
    kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout=5m
    if [ $? -eq 0 ]; then
        echo "デプロイメントのロールアウトが完了しました。更新されたメモリリミットで新しいPodが実行されているはずです。"
        echo "数分後、'kubectl top pods -n $NAMESPACE' でメモリ使用量を確認してください。"
    else
        echo "デプロイメントのロールアウトが失敗またはタイムアウトしました (5分)。詳細については 'kubectl describe deployment $DEPLOYMENT_NAME -n $NAMESPACE' を確認してください。"
        exit 1
    fi
else
    echo "デプロイメント '$DEPLOYMENT_NAME' へのパッチ適用に失敗しました。"
    exit 1
fi