# Rewrites a .tftest.hcl so OpenTofu accepts it. Reads the whole file (RS) and takes
# -v moddir=<module dir> -v tofu=<binary> -v exprfile=<scratch file> -v empty=<empty dir>.
#  - drops override_during lines (Terraform-only argument)
#  - replaces file("...") and jsonencode(...) calls with their literal value, because
#    OpenTofu rejects function calls in override and mock values.
function esc(s) { gsub(/\$\{/, "$${", s); gsub(/%\{/, "%%{", s); return s }
function span_end(s, start,    i, c, depth, q) {
  depth = 0; q = 0
  for (i = start; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
    if (c == "\"") { q = 1; continue }
    if (c == "(") depth++
    else if (c == ")") { depth--; if (depth == 0) return i }
  }
  return 0
}
function evaluate(expr, kind,    tmp, cmd, out, line, path) {
  if (kind == "file") {
    path = expr; sub(/^file\("/, "", path); sub(/"\)$/, "", path)
    cmd = "cd '" moddir "' && jq -Rs . '" path "'"
  } else {
    tmp = exprfile
    printf "%s\n", expr > tmp; close(tmp)
    cmd = "cd '" empty "' && " tofu " console < '" tmp "' 2>/dev/null"
  }
  out = ""
  while ((cmd | getline line) > 0) out = (out == "" ? line : out "\n" line)
  close(cmd); sub(/\n+$/, "", out)
  if (kind == "file") return (out ~ /^"/ ? esc(out) : "")
  return (out ~ /^"/ && out !~ /\n/ ? esc(out) : "")
}
BEGIN { RS = "\001"; ORS = "" }
{
  text = $0
  gsub(/(^|\n)[ \t]*override_during[ \t]*=[^\n]*/, "", text)
  result = ""
  while (match(text, /(file|jsonencode)\(/)) {
    kind = substr(text, RSTART, RLENGTH - 1)
    pre = substr(text, 1, RSTART - 1)
    end = span_end(text, RSTART + RLENGTH - 1)
    if (!end) { result = result pre substr(text, RSTART); text = ""; break }
    expr = substr(text, RSTART, end - RSTART + 1)
    lit = evaluate(expr, kind)
    result = result pre (lit != "" ? lit : expr)
    text = substr(text, end + 1)
  }
  print result text
}
