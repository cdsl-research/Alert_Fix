#!/bin/bash

# KubernetesのRedmineコンテナのメモリ使用率が高いアラートに対処するスクリプトです。
# Redmineコンテナのメモリリミットを増加させ、Podをローリングアップデートします。

NAMESPACE="redmine"
# アラート対象のPod名は redmine-5599f556d7-hd7hd です。
# このPodを管理しているDeploymentの名前を特定します。
# 通常は "redmine" か "redmine-5599f556d7" のような形式ですが、ここでは "redmine" と仮定します。
# もし正確なDeployment名が不明な場合は、事前に `kubectl get deployments -n $NAMESPACE` で確認し、
# DEPLOYMENT_NAME変数を適切な値に修正してください。
DEPLOYMENT_NAME="redmine"
# アラート情報からコンテナ名は "redmine" です。
CONTAINER_NAME="redmine"

echo "--- Redmineコンテナのメモリ使用率アラートに対処開始 ---"
echo "対象Deployment: $DEPLOYMENT_NAME, Namespace: $NAMESPACE, コンテナ: $CONTAINER_NAME"

# 1. 現在のPodの状態とリソース使用状況を表示
echo ""
echo "--- 1. 現在のPodとリソース使用状況 ---"
kubectl get pods -n "$NAMESPACE" -o wide
kubectl top pods -n "$NAMESPACE" || echo "kubectl top pods コマンドの実行に失敗しました。metrics-serverが導入されているか確認してください。"

# 2. Redmineコンテナの現在のメモリリミットを取得
echo ""
echo "--- 2. 現在のメモリリミットを取得中 ---"
CURRENT_LIMIT_STR=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CONTAINER_NAME\")].resources.limits.memory}")

if [ -z "$CURRENT_LIMIT_STR" ]; then
    echo "エラー: Deployment '$DEPLOYMENT_NAME' のコンテナ '$CONTAINER_NAME' のメモリリミットが見つかりませんでした。"
    echo "Deployment名またはコンテナ名が正しいか確認してください。"
    exit 1
fi

echo "現在のメモリリミット: $CURRENT_LIMIT_STR"

# 3. 取得したメモリリミット文字列をMiBに変換
CURRENT_LIMIT_MIB=0
if [[ "$CURRENT_LIMIT_STR" =~ ([0-9]+)Mi ]]; then
    CURRENT_LIMIT_MIB=${BASH_REMATCH[1]}
    echo "パースされた現在のメモリリミット (MiB): $CURRENT_LIMIT_MIB MiB"
elif [[ "$CURRENT_LIMIT_STR" =~ ([0-9]+)Gi ]]; then
    CURRENT_LIMIT_GIB=${BASH_REMATCH[1]}
    CURRENT_LIMIT_MIB=$((CURRENT_LIMIT_GIB * 1024))
    echo "パースされた現在のメモリリミット (MiB): $CURRENT_LIMIT_MIB MiB"
else
    echo "エラー: 現在のメモリリミット '$CURRENT_LIMIT_STR' の形式をパースできませんでした。"
    echo "MiまたはGi単位での指定を想定しています。異なる形式の場合はスクリプトを修正してください。"
    exit 1
fi

# 4. 新しいメモリリミットを計算 (現在のリミットから25%増加)
# アラートが90%を超えているため、十分な余裕を持たせるために25%増加させます。
INCREASE_PERCENT=25
NEW_LIMIT_MIB=$((CURRENT_LIMIT_MIB * (100 + INCREASE_PERCENT) / 100))

# 少なくとも32MiBの増加を保証（計算上の増加量が少ない場合）
MIN_INCREASE_MIB=32
if (( NEW_LIMIT_MIB - CURRENT_LIMIT_MIB < MIN_INCREASE_MIB )); then
    NEW_LIMIT_MIB=$((CURRENT_LIMIT_MIB + MIN_INCREASE_MIB))
    echo "計算された増加量が ${MIN_INCREASE_MIB}MiB 未満のため、最低増加量 ${MIN_INCREASE_MIB}MiB を適用します。"
fi

NEW_LIMIT_STR="${NEW_LIMIT_MIB}Mi"

echo "新しいメモリリミット (現在の ${INCREASE_PERCENT}% 増): ${NEW_LIMIT_STR}"

# 5. 新しいメモリリミットをDeploymentに適用
echo ""
echo "--- 5. Deployment '$DEPLOYMENT_NAME' に新しいメモリリミットを適用中 ---"
kubectl set resources deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -c "$CONTAINER_NAME" --limits=memory="$NEW_LIMIT_STR"

if [ $? -eq 0 ]; then
    echo "メモリリミットが正常に更新されました。これにより、Deploymentのローリングアップデートが開始されます。"
    echo "Podが順次再作成され、新しいメモリリミットが適用されます。"
    echo "Podの再作成が完了するまでしばらくお待ちください..."
else
    echo "エラー: メモリリミットの更新に失敗しました。kubectlの出力でエラーを確認してください。"
    exit 1
fi

# 6. ロールアウトの進行状況を監視
echo ""
echo "--- 6. ロールアウトのステータスを確認中 (最大5分) ---"
kubectl rollout status deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout=5m

if [ $? -eq 0 ]; then
    echo "ロールアウトが正常に完了しました。"
else
    echo "警告: ロールアウトが時間内に完了しませんでした。手動で `kubectl rollout status deployment $DEPLOYMENT_NAME -n $NAMESPACE` を実行してステータスを確認してください。"
fi

# 7. 更新後のPodの状態とリソース使用状況を表示
echo ""
echo "--- 7. 更新後のPodとリソース使用状況 ---"
kubectl get pods -n "$NAMESPACE" -o wide
kubectl top pods -n "$NAMESPACE" || echo "kubectl top pods コマンドの実行に失敗しました。"

echo ""
echo "--- Redmineコンテナのメモリリミット増加処理が完了しました ---"
echo "数分後、Prometheusなどの監視ツールでアラートが解消されたか確認してください。"
echo "問題が解決しない場合、アプリケーションのメモリリークの可能性も考慮し、より詳細な調査が必要です。"