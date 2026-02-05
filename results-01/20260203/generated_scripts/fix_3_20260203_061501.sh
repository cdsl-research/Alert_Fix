#!/bin/bash

# 対象のKubernetesネームスペースとデプロイメント名
NAMESPACE="redmine"
DEPLOYMENT_NAME="redmine"
CONTAINER_NAME="redmine" # Redmineコンテナの正確な名前（通常はデプロイメント名と同じか、アプリケーション名）

# 現在のRedmine Pod (redmine-6f886649cb-q9z6k) のメモリ使用量は174Miです。
# アラートは「コンテナのメモリ使用量がリミットの90%に達した」ことを示しているため、
# メモリリミットを引き上げることが直接的な解決策となります。
# ノードにはまだ1.3Giの空きメモリがあるため、リミットを増やすことは可能です。
# 174Miの使用量に対し、より十分な余裕を持たせるため、メモリリミットを512Miに設定します。
# メモリリクエストは、通常limits以下に設定されるべきであり、ここでは256Miに設定します。
NEW_MEMORY_LIMIT="512Mi"
NEW_MEMORY_REQUEST="256Mi"

echo "--- アラートと現在の状況 ---"
echo "アラート名: Internal redmine memory check"
echo "ネームスペース: ${NAMESPACE}"
echo "現在のRedmine Pod (kubectl top podsから): redmine-6f886649cb-q9z6k"
echo "コンテナ名: ${CONTAINER_NAME}"
echo "現在のPodメモリ使用量: 174Mi"
echo "--------------------------"

echo "デプロイメント '${DEPLOYMENT_NAME}' のメモリリミットを更新します。"

# デプロイメントが存在するか確認
if ! kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    echo "エラー: ネームスペース '${NAMESPACE}' にデプロイメント '${DEPLOYMENT_NAME}' が見つかりません。"
    exit 1
fi

echo "更新前のRedmineコンテナのリソース設定:"
kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER_NAME}')].resources}"
echo "" # jsonpath出力の後に改行を追加

# kubectl patchコマンドを使って、メモリリミットとリクエストを更新するためのJSONパッチを構築
# このパッチは、デプロイメントのPodテンプレート内の特定のコンテナを対象とします。
PATCH_JSON=$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "${CONTAINER_NAME}",
            "resources": {
              "limits": {
                "memory": "${NEW_MEMORY_LIMIT}"
              },
              "requests": {
                "memory": "${NEW_MEMORY_REQUEST}"
              }
            }
          }
        ]
      }
    }
  }
}
EOF
)

echo "コンテナ '${CONTAINER_NAME}' のメモリリミットを ${NEW_MEMORY_LIMIT}、リクエストを ${NEW_MEMORY_REQUEST} に設定するパッチを適用中..."
echo "${PATCH_JSON}" | kubectl patch deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --patch-file /dev/stdin

if [ $? -eq 0 ]; then
    echo "デプロイメント '${DEPLOYMENT_NAME}' の更新が正常に開始されました。"
    echo "Kubernetesはローリングアップデートを実行し、更新されたリソース設定で新しいPodを作成します。"
else
    echo "デプロイメント '${DEPLOYMENT_NAME}' のメモリリミット更新に失敗しました。"
    echo "コマンド出力とKubernetes環境を確認してください。"
    exit 1
fi

echo "デプロイメントのロールアウト完了を待機中..."
# ロールアウトが完了するか、最大5分間待機
kubectl rollout status deployment/"${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout=5m

if [ $? -eq 0 ]; then
    echo "デプロイメントのロールアウトが正常に完了しました。"
else
    echo "デプロイメントのロールアウトがタイムアウトしたか、エラーが発生しました。"
    echo "'kubectl rollout status deployment/${DEPLOYMENT_NAME} -n ${NAMESPACE}' および 'kubectl get events -n ${NAMESPACE}' で詳細を確認してください。"
fi

echo ""
echo "--- 処理後の確認コマンド ---"
echo "1. 新しいPodのステータスを確認します:"
echo "   kubectl get pods -n ${NAMESPACE} -o wide"
echo "2. 新しいPodのメモリ使用量を確認します（メトリクスが更新されるまで時間がかかる場合があります）:"
echo "   kubectl top pods -n ${NAMESPACE}"
echo "3. 更新されたデプロイメント設定を確認します:"
echo "   kubectl get deployment ${DEPLOYMENT_NAME} -n ${NAMESPACE} -o yaml | grep -A 5 'resources:'"
echo ""
echo "新しいPodが稼働し、そのメモリ使用量が新しいリミットに対して90%を下回れば、アラートは解消されるはずです。"