#!/bin/bash

# アラート対象のnamespaceとDeploymentを特定
NAMESPACE="redmine"
CONTAINER_NAME="redmine" # アラート情報内のcontainerラベルから取得
# アラート情報内のPod名 'redmine-6f886649cb-q9z6k' や、現在のPod名 'redmine-7cdcd4d9dd-m4wvk' から、
# その親Deployment名は一般的に 'redmine' であると推測します。
DEPLOYMENT_NAME="redmine"

echo "Redmineコンテナのメモリ使用率が高いアラートに対処します。"
echo "対象Deployment: $DEPLOYMENT_NAME (名前空間: $NAMESPACE)"
echo "対象コンテナ: $CONTAINER_NAME"

# 現在のRedmine Deploymentが存在するか確認
if ! kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "エラー: Deployment '$DEPLOYMENT_NAME' が名前空間 '$NAMESPACE' に見つかりません。"
    echo "Deployment名が異なる場合は、スクリプト内の 'DEPLOYMENT_NAME' 変数を修正してください。"
    exit 1
fi

echo "現在の'$DEPLOYMENT_NAME' Deploymentの'$CONTAINER_NAME'コンテナのリソースリミットを確認します..."
# 現在のメモリリミットを取得
CURRENT_MEMORY_LIMIT=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CONTAINER_NAME\")].resources.limits.memory}" 2>/dev/null)
if [ -z "$CURRENT_MEMORY_LIMIT" ]; then
    echo "注意: '$CONTAINER_NAME' コンテナに現在のメモリリミットが設定されていません。"
    CURRENT_MEMORY_LIMIT="未設定"
fi
echo "現在のメモリリミット: $CURRENT_MEMORY_LIMIT"

# アラートが90%で発生していること、kubectl topで161Miが確認されていることを考慮し、
# メモリリミットが低すぎると判断し、これを引き上げます。
# 161Miが90%だとすると、現在のリミットは約178Miと推測されます。
# これを十分に超える256Miに設定します。
NEW_MEMORY_LIMIT="256Mi"

echo "Deployment '$DEPLOYMENT_NAME' の'$CONTAINER_NAME'コンテナのメモリリミットを ${NEW_MEMORY_LIMIT} に更新します。"

# kubectl set resources コマンドを使用してメモリリミットを更新します。
# このコマンドはDeploymentを更新し、新しいリミットでPodが再起動します (ローリングアップデート)。
# リクエストを指定しない場合、Kubernetesはデフォルトでリミットと同じ値をリクエストに設定します。
kubectl set resources deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" --container="$CONTAINER_NAME" --limits=memory="$NEW_MEMORY_LIMIT"

# 変更が適用され、ローリングアップデートが開始されたか確認します。
echo "変更が適用され、ローリングアップデートが開始されたか確認します..."
kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE"

echo "Redmine Deploymentのメモリリミットが ${NEW_MEMORY_LIMIT} に更新されました。"
echo "これにより、新しいPodはより多くのメモリリソースで起動し、メモリ不足アラートが解消されることが期待されます。"
echo "引き続き監視を行い、必要であればさらなるリソース調整や最適化（例: CPUリソースの調整、レプリカ数の増加）を検討してください。"