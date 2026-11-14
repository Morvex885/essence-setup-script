#!/bin/bash
SUB_DIR={{sub_dir}}
LIST="${SUB_DIR}/expiry.list"
[[ -f "$LIST" ]] || exit 0
NOW=$(date +%s)
( flock 9
  while read -r token expires; do
    [[ -z "$token" ]] && continue
    if [[ "$expires" -le "$NOW" ]]; then
      rm -f "${SUB_DIR}/${token}.yaml"
    else
      printf '%s %s\n' "$token" "$expires"
    fi
  done < "$LIST" > "${LIST}.tmp"
  mv "${LIST}.tmp" "$LIST"
) 9>"${SUB_DIR}/.expiry.lock"
