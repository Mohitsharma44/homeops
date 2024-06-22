* Export the following environment variables
```
# For bootstrapping flux
export GITHUB_TOKEN=<from github -> finegrained token>
export GITHUB_USER=Mohitsharma44
export GITHUB_REPO=homeops

# Path to the sops key for secrets encryption
export SOPS_AGE_KEY_FILE=$HOME/.sops/key.txt
```

* Create sops age secret in the cluster
```
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$SOPS_AGE_KEY_FILE
```

* Flux bootstrap:

```
flux bootstrap github \
  --token-auth \
  --owner=Mohitsharma44 \
  --repository=homeops \
  --branch=main \
  --path=clusters/minipcs \
  --personal
```
