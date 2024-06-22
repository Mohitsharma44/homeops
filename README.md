* Export the following environment variables
```
# For bootstrapping flux
export GITHUB_TOKEN=<from github -> finegrained token>
export GITHUB_USER=Mohitsharma44
export GITHUB_REPO=homeops

# Path to the sops key for secrets encryption
export SOPS_AGE_KEY_FILE=$HOME/.sops/key.txt
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
