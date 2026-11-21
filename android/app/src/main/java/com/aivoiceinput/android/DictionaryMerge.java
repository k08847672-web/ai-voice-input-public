package com.aivoiceinput.android;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TreeSet;

final class DictionaryMerge {
    static final class Result {
        final Map<String, String> entries;
        final boolean conflict;

        Result(Map<String, String> entries, boolean conflict) {
            this.entries = entries;
            this.conflict = conflict;
        }
    }

    static Result merge(
            Map<String, String> baseline,
            Map<String, String> local,
            Map<String, String> remote) {
        Map<String, String> entries = new LinkedHashMap<>();
        TreeSet<String> keys = new TreeSet<>();
        keys.addAll(baseline.keySet());
        keys.addAll(local.keySet());
        keys.addAll(remote.keySet());
        boolean conflict = false;
        for (String key : keys) {
            String original = baseline.get(key);
            String here = local.get(key);
            String there = remote.get(key);
            String selected;
            if (java.util.Objects.equals(here, original)) {
                selected = there;
            } else if (java.util.Objects.equals(there, original)
                    || java.util.Objects.equals(here, there)) {
                selected = here;
            } else {
                selected = here;
                conflict = true;
            }
            if (selected != null) {
                entries.put(key, selected);
            }
        }
        return new Result(entries, conflict);
    }
}
