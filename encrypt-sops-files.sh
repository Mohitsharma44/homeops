#!/usr/bin/env bash

EXIT_CODE=0

for file in "$@"; do
	if [[ -f "$file" ]]; then
		if ! grep -q 'ENC\[[A-Z0-9_]*,data:.*,type:.*\]' "$file"; then
			echo "File $file is not encrypted, encrypting..."
			if [[ "$file" =~ \.yaml ]]; then
				sops --encrypt --in-place --input-type=yaml "$file" || EXIT_CODE=1
			elif [[ "$file" =~ \.json ]]; then
				sops --encrypt --in-place --input-type=json "$file" || EXIT_CODE=1
			elif [[ "$file" =~ \.env ]]; then
				sops --encrypt --in-place --input-type=dotenv "$file" || EXIT_CODE=1
			else
				sops --encrypt --in-place "$file" || EXIT_CODE=1
			fi
		fi
	fi
done

exit $EXIT_CODE
