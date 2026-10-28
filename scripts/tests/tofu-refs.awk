# Replaces run.<name>.<output> references with literal values. -v map=<file> holds one
# "<reference><TAB><json value>" per line, longest references first so a prefix never wins.
BEGIN {
  while ((getline line < map) > 0) {
    tab = index(line, "\t")
    refs[++n] = substr(line, 1, tab - 1)
    lit = substr(line, tab + 1)
    gsub(/\$\{/, "$${", lit)
    gsub(/%\{/, "%%{", lit)
    lits[n] = lit
  }
  RS = "\001"; ORS = ""
}
{
  text = $0
  for (i = 1; i <= n; i++) {
    out = ""
    while ((p = index(text, refs[i])) > 0) {
      out = out substr(text, 1, p - 1) lits[i]
      text = substr(text, p + length(refs[i]))
    }
    text = out text
  }
  print text
}
