# Builds a probe test file: the file level blocks of a .tftest.hcl and one run (-v name=<run>), without
# its asserts, plus an assert that fails on purpose and prints the value of one output (-v path=<output
# path>) as PROBE=<json>. OpenTofu only exposes run.<name> to the next run, so the values other runs
# compare against are read this way.
function brace_end(s, start,    i, c, depth, q) {
  depth = 0; q = 0
  for (i = start; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
    if (c == "\"") { q = 1; continue }
    if (c == "{") depth++
    else if (c == "}") { depth--; if (depth == 0) return i }
  }
  return 0
}
BEGIN { RS = "\001"; ORS = "" }
{
  text = $0
  if (!match(text, /(^|\n)run "[^"]+" \{/)) exit 1
  print substr(text, 1, RSTART - 1) "\n"
  start = index(text, "run \"" name "\" {")
  if (!start) exit 1
  open = start + index(substr(text, start), "{") - 1
  block = substr(text, start, brace_end(text, open) - start + 1)
  while (match(block, /\n[ \t]*assert \{/)) {
    a_open = RSTART + RLENGTH - 1
    block = substr(block, 1, RSTART - 1) substr(block, brace_end(block, a_open) + 1)
  }
  sub(/\n\}$/, "", block)
  print block "\n\n  assert {\n    condition     = length(nonsensitive(jsonencode(output." path "))) < 0\n    error_message = \"PROBE=${nonsensitive(jsonencode(output." path "))}\"\n  }\n}\n"
}
