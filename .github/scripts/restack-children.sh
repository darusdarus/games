#!/usr/bin/env bash
# Replay stacked pull requests onto a parent that just merged.
# A squash merge puts the parent on main under a new commit. Child branches
# still contain the old commit, so GitHub's retarget conflicts on the shared
# file. This rebases only the commits that came after the parent.
set -euo pipefail

APPLY=0
OLD_TIP=""
NEW_TIP=""
MERGED_PR=""
REPO="${GITHUB_REPOSITORY:-darusdarus/games}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --old-tip) OLD_TIP=$2; shift 2 ;;
    --new-tip) NEW_TIP=$2; shift 2 ;;
    --merged-pr) MERGED_PR=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$OLD_TIP" || -z "$NEW_TIP" ]]; then
  echo "need --old-tip and --new-tip" >&2
  exit 2
fi

git fetch origin main
if ! git cat-file -e "${NEW_TIP}^{commit}" 2>/dev/null; then
  echo "merge commit $NEW_TIP is not in this clone" >&2
  exit 1
fi

mapfile -t PRS < <(gh pr list --repo "$REPO" --state open --limit 100 --json number,headRefName,headRefOid --jq '.[] | "\(.number)\t\(.headRefName)\t\(.headRefOid)"')

for row in "${PRS[@]}"; do
  ref="${row#*$'\t'}"
  ref="${ref%%$'\t'*}"
  if [[ ! "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "skip unsafe ref $ref" >&2
    continue
  fi
  git fetch origin "$ref"
done

if ! git cat-file -e "${OLD_TIP}^{commit}" 2>/dev/null; then
  echo "parent commit $OLD_TIP is gone and no open pull request still points at it"
  exit 0
fi

direct_children() {
  local old="$1" row num ref sha other other_sha blocked
  for row in "${PRS[@]}"; do
    IFS=$'\t' read -r num ref sha <<<"$row"
    if [[ "$sha" == "$old" ]]; then continue; fi
    if ! git merge-base --is-ancestor "$old" "$sha" 2>/dev/null; then continue; fi
    blocked=0
    for other in "${PRS[@]}"; do
      IFS=$'\t' read -r _ _ other_sha <<<"$other"
      if [[ "$other_sha" == "$sha" || "$other_sha" == "$old" ]]; then continue; fi
      if git merge-base --is-ancestor "$old" "$other_sha" 2>/dev/null && git merge-base --is-ancestor "$other_sha" "$sha" 2>/dev/null; then
        blocked=1
        break
      fi
    done
    if [[ "$blocked" -eq 0 ]]; then
      printf '%s\t%s\t%s\n' "$num" "$ref" "$sha"
    fi
  done
}

restack_one() {
  local num="$1" ref="$2" expected="$3" onto="$4" parent="$5"
  local wt newsha
  wt=$(mktemp -d)
  git worktree add --detach "$wt" "origin/$ref" >&2
  if ! git -C "$wt" rebase --onto "$onto" "$parent" >&2; then
    git -C "$wt" rebase --abort >&2 || true
    git worktree remove --force "$wt" >&2
    echo "conflict restacking #$num ($ref)" >&2
    if [[ "$APPLY" -eq 1 && -n "$MERGED_PR" ]]; then
      gh pr comment "$num" --repo "$REPO" --body "Could not restack this onto the merge of #$MERGED_PR. The rebase hit a conflict, so the branch was left as it is."
    fi
    return 1
  fi
  newsha=$(git -C "$wt" rev-parse HEAD)
  if [[ "$newsha" == "$expected" ]]; then
    echo "#$num $ref already at $newsha" >&2
    git worktree remove --force "$wt" >&2
    printf '%s\n' "$newsha"
    return 0
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    git -C "$wt" push --force-with-lease="refs/heads/$ref:$expected" origin "HEAD:refs/heads/$ref" >&2
    if [[ -n "$MERGED_PR" ]]; then
      gh pr comment "$num" --repo "$REPO" --body "Restacked onto the merge of #$MERGED_PR. This branch now has only its own commits, so the squash of the parent does not conflict here."
    fi
  else
    echo "would restack #$num $ref $expected -> $newsha onto $onto" >&2
  fi
  git worktree remove --force "$wt" >&2
  printf '%s\n' "$newsha"
}

walk() {
  local old="$1" new="$2" num ref sha newsha
  while IFS=$'\t' read -r num ref sha; do
    [[ -z "${num:-}" ]] && continue
    echo "child #$num $ref of $old"
    if newsha=$(restack_one "$num" "$ref" "$sha" "$new" "$old"); then
      newsha=$(printf '%s\n' "$newsha" | tail -n 1)
      walk "$sha" "$newsha"
    fi
  done < <(direct_children "$old")
}

walk "$OLD_TIP" "$NEW_TIP"
