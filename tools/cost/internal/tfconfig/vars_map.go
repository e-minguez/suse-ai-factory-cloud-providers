package tfconfig

import "sort"

// MapKeys returns the sorted keys of the map or object variable name; nil
// when unset, null or empty. Values are never returned.
func (v *Vars) MapKeys(name string) []string {
	val, ok := v.value(name)
	if !ok || val.IsNull() || !val.IsKnown() {
		return nil
	}
	if !val.Type().IsMapType() && !val.Type().IsObjectType() {
		v.addErr("variable %q: expected a map", name)
		return nil
	}
	var keys []string
	for it := val.ElementIterator(); it.Next(); {
		k, _ := it.Element()
		keys = append(keys, k.AsString())
	}
	sort.Strings(keys)
	return keys
}
