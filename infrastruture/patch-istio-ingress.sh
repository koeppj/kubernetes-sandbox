microk8s kubectl -n istio-system patch deployment istio-ingressgateway \
  --type='merge' \
  -p '{
    "spec": {
      "template": {
        "spec": {
          "nodeSelector": {
            "gateway-okay": "true"
          }
        }
      }
    }
  }'
