#!/bin/bash

# アラート情報から取得した設定値
NAMESPACE="redmine"
# アラートのpod名 'redmine-5599f556d7-hd7hd' は 'redmine' Deploymentによって管理されていると想定します。
DEPLOYMENT_NAME="redmine" 
CONTAINER_NAME="redmine" # アラートのラベル 'container: redmine' より

# 環境情報から取得したRedmine Podの現在のメモリ使用量 (MiB)
# 'kubectl top pods -n redmine' の出力: redmine-5599f556d7-hd7hd   1m           163Mi
CURRENT_MEMORY_USAGE_MIB=163

echo "--- Redmine Pod メモリ使用量アラート対処スクリプト ---"
echo "対象: Deployment '$DEPLOYMENT_NAME' (Namespace: '$NAMESPACE')"
echo "コンテナ: '$CONTAINER_NAME'"
echo "現在のPodのメモリ使用量: ${CURRENT_MEMORY_USAGE_MIB}MiB"

# 現在のメモリリソース制限とリクエストをDeploymentから取得
echo ""
echo "現在のメモリリソース設定の確認..."
CURRENT_LIMITS_MEM_STR=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o=jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER_NAME')].resources.limits.memory}" 2>/dev/null)
CURRENT_REQUESTS_MEM_STR=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o=jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER_NAME')].resources.requests.memory}" 2>/dev/null)

if [ -z "$CURRENT_LIMITS_MEM_STR" ]; then
    echo "  現在のメモリ制限: 未設定"
else
    echo "  現在のメモリ制限: $CURRENT_LIMITS_MEM_STR"
fi
if [ -z "$CURRENT_REQUESTS_MEM_STR" ]; then
    echo "  現在のメモリリクエスト: 未設定"
else
    echo "  現在のメモリリクエスト: $CURRENT_REQUESTS_MEM_STR"
fi

# 推奨される新しいメモリ制限とリクエストの計算
# アラートは現在の使用量(163MiB)が90%に達していることを示唆しています。
# したがって、現在の制限は約 163MiB / 0.9 = 181MiB と推測されます。
# 前回試行で改善が見られなかったことを考慮し、十分な余裕を持たせるため、
# メモリ制限を 512 MiB に設定することを提案します。
NEW_MEMORY_LIMIT_MIB=512
NEW_MEMORY_LIMIT="${NEW_MEMORY_LIMIT_MIB}Mi"

# メモリリクエストは制限の約50%に設定 (一般的なプラクティス)
NEW_MEMORY_REQUEST_MIB=$(( NEW_MEMORY_LIMIT_MIB / 2 ))
NEW_MEMORY_REQUEST="${NEW_MEMORY_REQUEST_MIB}Mi"

echo ""
echo "--- 提案される変更 ---"
echo "  新しいメモリ制限 (limits.memory): $NEW_MEMORY_LIMIT"
echo "  新しいメモリリクエスト (requests.memory): $NEW_MEMORY_REQUEST"
echo ""
echo "この変更により、Redmineコンテナはより多くのメモリを使用できるようになります。"
echo "Deploymentが更新され、新しいメモリ設定を持つPodが再作成されます。"
echo "これにより、一時的にRedmineサービスが中断する可能性があります。"

read -p "上記変更を適用しますか？ (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo ""
    echo "Deployment '$DEPLOYMENT_NAME'のメモリリソースを更新中..."
    
    # kubectl set resources コマンドを使用して、指定されたコンテナのメモリリソースを更新します。
    # このコマンドはDeploymentを更新し、ローリングアップデートをトリガーします。
    kubectl set resources deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" \
      --container="$CONTAINER_NAME" \
      --requests=memory="$NEW_MEMORY_REQUEST" \
      --limits=memory="$NEW_MEMORY_LIMIT"

    if [ $? -eq 0 ]; then
        echo "メモリリソースが正常に更新されました。"
        echo "新しいPodが作成され次第、Redmineサービスのメモリ使用量が安定するか監視してください。"
        echo ""
        echo "数分後に以下のコマンドで状態を確認してください:"
        echo "  - Podのステータスと新しいPodの起動状況:"
        echo "    kubectl get pods -n $NAMESPACE -o wide"
        echo "  - 新しいPodのメモリ使用量:"
        echo "    kubectl top pods -n $NAMESPACE"
        echo "  - アラートが解消されたか、Prometheus/Alertmanagerのダッシュボードを確認"
    else
        echo "エラー: メモリリソースの更新に失敗しました。"
        echo "手動でDeployment '$DEPLOYMENT_NAME' の設定を確認してください:"
        echo "  kubectl edit deployment $DEPLOYMENT_NAME -n $NAMESPACE"
    fi
else
    echo "操作はキャンセルされました。"
fi