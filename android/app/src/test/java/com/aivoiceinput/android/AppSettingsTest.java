package com.aivoiceinput.android;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

public final class AppSettingsTest {
    @Test
    public void normalizesAndDeduplicatesHotwords() {
        assertEquals(
                Arrays.asList("Codex", "语音输入"),
                AppSettings.parseLines(" Codex \n\n语音输入\nCodex\n"));
    }

    @Test
    public void parsesOnlyCompleteDictionaryEntries() {
        Map<String, String> expected = new LinkedHashMap<>();
        expected.put("扣得克斯", "Codex");
        expected.put("爱哦艾", "AI");
        assertEquals(
                expected,
                AppSettings.parseDictionary(
                        "扣得克斯 = Codex\n无效行\n=空\n爱哦艾=AI\n"));
    }

    @Test
    public void dictionarySerializationKeepsInsertionOrder() {
        Map<String, String> dictionary = new LinkedHashMap<>();
        dictionary.put("一", "1");
        dictionary.put("二", "2");
        assertEquals("一=1\n二=2", AppSettings.serializeDictionary(dictionary));
    }
}
