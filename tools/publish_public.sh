#!/bin/zsh
# Snapshot HEAD onto the orphan `public` branch (the public GitHub repo's main), leaving out
# design material (docs, mockups, previews, screenshots) and anything gitignored. Builds never go
# public: players build their own .pdx. Review the diff, then push with:
#   git push github public:main
# Usage: zsh tools/publish_public.sh "commit message"
set -euo pipefail
ROOT="${0:A:h:h}"
MSG="${1:-Update from development}"
EXCLUDE=(
  docs
  tools/assets/preview
  tools/assets/archive/preview
  tools/assets/humanoid/preview
  tools/assets/mockup_ref
  tools/assets/readme
  tools/tv/preview
)
WT="$(mktemp -d)/public"
cd "$ROOT"
if git show-ref -q refs/heads/public; then
  git worktree add -q "$WT" public
else
  git worktree add -q --detach "$WT"
  git -C "$WT" checkout -q --orphan public
fi
git -C "$WT" rm -rqf --ignore-unmatch . >/dev/null
git archive HEAD | tar -x -C "$WT"
for p in $EXCLUDE; do rm -rf "$WT/$p"; done
mkdir -p "$WT/docs" && cp docs/CREDITS.md "$WT/docs/CREDITS.md"
git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then echo "nothing to publish"; else git -C "$WT" commit -q -m "$MSG"; fi
git -C "$WT" log --oneline -1
git worktree remove "$WT"
