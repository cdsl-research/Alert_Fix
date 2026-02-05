#!/bin/bash

# このスクリプトは、Redmineコンテナのメモリ使用率が高いために発生しているアラートを解決するため、
# Kubernetes Deploymentのメモリリソース設定（limitsとrequests）を増強します。
# 以前の試行で改善が見られなかったとのことなので、根本的なリソース不足に対応します。

# 環境変数
NAMESPACE="redmine"
DEPLOYMENT_NAME="redmine"
CONTAINER_NAME="redmine" # アラート情報からコンテナ名が'redmine'であることを確認

# 新しいメモリリソースの設定値
# 現在のPodのメモリ使用量 (kubectl top pods) が164Miで、
# 使用率が95.9% (before=95.90928819444444) であることから、
# 現在のメモリリミットは約 164Mi / 0.959 ≈ 171Mi と推測されます。
# これを大幅に増やし、例えば512Miを新しいリミットとします。
# リクエストはリミットの半分程度、または現在の使用量より少し高めに設定することが推奨されます。
NEW_MEMORY_LIMIT="512Mi"
NEW_MEMORY_REQUEST="256Mi"

echo "Redmineコンテナのメモリリミットを増やすスクリプトを実行します。"
echo "対象: namespace='${NAMESPACE}', deployment='${DEPLOYMENT_NAME}', container='${CONTAINER_NAME}'"
echo "新しいメモリリミット: ${NEW_MEMORY_LIMIT}"
echo "新しいメモリリクエスト: ${NEW_MEMORY_REQUEST}"
echo ""

# 依存ツール 'yq' の存在チェック (YAML処理のため、存在しない場合は警告)
if ! command -v yq &> /dev/null; then
    echo "警告: 'yq' コマンドが見つかりません。一部の出力表示が期待通りに行われない可能性があります。"
    echo "推奨: 'yq' をインストールしてください (例: brew install yq または go install github.com/mikefarah/yq@latest)。"
    echo ""
fi

# 1. 現在のRedmine Deploymentのリソース設定を表示
echo "### 現在のRedmine Deploymentのリソース設定 ###"
if command -v yq &> /dev/null; then
  kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o yaml | \
    yq '.spec.template.spec.containers[] | select(.name == "'"${CONTAINER_NAME}"'") | .resources'
else
  # yqがない場合の代替表示 (limitsとrequestsのメモリ部分のみ)
  echo "yqが利用できないため、limitsとrequestsのメモリ設定のみ表示します。"
  kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o yaml | \
    grep -E '^\s*(limits:|requests:|memory:)' | sed 's/^/\t/'
fi

if [ $? -ne 0 ]; then
  echo "エラー: Redmine Deployment '${DEPLOYMENT_NAME}' の情報を取得できませんでした。namespaceやdeployment名を確認してください。"
  exit 1
fi

echo ""

# 2. Deploymentにパッチを適用してメモリリソースを更新
echo "### Deployment '${DEPLOYMENT_NAME}' のメモリリソースを更新します... ###"
# Strategic Merge Patch を使用して、指定したコンテナのresourcesセクションを更新
PATCH_JSON="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${CONTAINER_NAME}\",\"resources\":{\"limits\":{\"memory\":\"${NEW_MEMORY_LIMIT}\"},\"requests\":{\"memory\":\"${NEW_MEMORY_REQUEST}\"}}}]}}}}"

kubectl patch deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --patch "${PATCH_JSON}"

if [ $? -ne 0 ]; then
  echo "エラー: Deploymentのパッチ適用に失敗しました。"
  exit 1
fi

echo "Deployment '${DEPLOYMENT_NAME}' が更新されました。新しいPodがデプロイされるのを待ちます..."

# 3. Podのローリングアップデートが完了するのを待つ
# Podが再作成され、新しいリソース設定が適用されるまで待ちます。
kubectl rollout status deployment/"${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout=5m

if [ $? -ne 0 ]; then
  echo "エラー: Deploymentのロールアウトがタイムアウトしました。手動でステータスを確認してください。"
  exit 1
fi

echo "新しいRedmine Podが正常にデプロイされました。"

# 4. 変更後のメモリリソース設定を確認
echo ""
echo "### 更新後のRedmine Deploymentのリソース設定 ###"
if command -v yq &> /dev/null; then
  kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o yaml | \
    yq '.spec.template.spec.containers[] | select(.name == "'"${CONTAINER_NAME}"'") | .resources'
else
  echo "yqが利用できないため、limitsとrequestsのメモリ設定のみ表示します。"
  kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o yaml | \
    grep -E '^\s*(limits:|requests:|memory:)' | sed 's/^/\t/'
fi

# 5. 新しいPodのtop情報を確認 (確認用)
echo ""
echo "### 新しいRedmine Podの現在のリソース使用量 (数秒後に表示) ###"
sleep 15 # 新しいPodが立ち上がってメトリクスを収集し始めるまで少し待つ
kubectl top pods -n "${NAMESPACE}" | grep "${DEPLOYMENT_NAME}"

echo ""
echo "スクリプトは完了しました。"
echo "Prometheusのアラートが解消されるか監視してください。"
echo "Redmineアプリケーションがより安定して動作するか確認してください。"
echo "必要であれば、メモリリミットの値をさらに調整してください。"