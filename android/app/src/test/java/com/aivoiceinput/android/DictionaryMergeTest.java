package com.aivoiceinput.android;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

public final class DictionaryMergeTest {
    @Test
    public void offlineDeleteDoesNotEraseOtherDeviceAddition() {
        Map<String, String> base = Collections.singletonMap("要删", "Old");
        Map<String, String> remote = new LinkedHashMap<>(base);
        remote.put("新词", "New");
        DictionaryMerge.Result result = DictionaryMerge.merge(base, Collections.emptyMap(), remote);
        assertEquals(Collections.singletonMap("新词", "New"), result.entries);
        assertFalse(result.conflict);
    }

    @Test
    public void sameKeyConflictKeepsLocal() {
        DictionaryMerge.Result result = DictionaryMerge.merge(
                Collections.singletonMap("词", "Old"),
                Collections.singletonMap("词", "Here"),
                Collections.singletonMap("词", "There"));
        assertEquals(Collections.singletonMap("词", "Here"), result.entries);
        assertTrue(result.conflict);
    }
}
