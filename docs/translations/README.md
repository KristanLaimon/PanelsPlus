# 🌍 Panels+ Translation Guide

Thank you for wanting to help translate **Panels+**! Whether you want to add a brand-new language or improve an existing translation, your help makes the plugin better for readers around the world.

---

## 🎯 How Translations Work

Panels+ uses simple translation text files called `.po` files, located in the [`locales/`](../../locales) directory:

- `locales/en.po` — English (The master template)
- `locales/es.po` — Spanish
- `locales/zh_CN.po` — Simplified Chinese (瑾轩小狼 / [@IMJXXL](https://github.com/IMJXXL), [#12](https://github.com/KristanLaimon/PanelsPlus/issues/12))
- `locales/your_language.po` — Your language

Inside a `.po` file, you will see pairs of text lines like this:

```po
msgid "Comic mode"
msgstr ""
```

- **`msgid`**: The original text in English (**do not change this, its the ID used inside the plugin's code to retrieve this translated text**).
- **`msgstr`**: Your translation goes between the quotes `""`.

For example, a Spanish translation looks like:

```po
msgid "Comic mode"
msgstr "Modo cómic"
```

---

## 🚀 How to Contribute

### Option 1: Via GitHub Issue

You can read an example of how a translation issue looks like here:

> https://github.com/KristanLaimon/PanelsPlus/issues/3

1. **Download the template**: Download or copy the [`locales/en.po`](../../locales/en.po) file.
2. **Translate**: Open the file in any text editor (Notepad, VS Code, TextEdit) or use a free translation helper app like **[Poedit](https://poedit.net/)**.
3. **Fill in your translations**: Replace the empty `msgstr ""` lines with translations in your language.
4. **Send it to us via GitHub Issue**:
   - Open a new issue on our **[GitHub Issues](https://github.com/KristanLaimon/BetterPanels/issues)** page.
   - Use our [`Translation-Issue.template.md`](Translation-Issue.template.md) template to structure your issue.
   - Be sure to add the **`translation`** detail / label when opening your issue (e.g. title `[Translation] Language Name` and select the `translation` label).
   - Attach your `.po` file to your comment or paste your translations into the template, and publish the issue, then we'll revise it and add it to the plugin if everything ok.

---

### Option 2: Via GitHub Pull Request

1. **Fork** this repository.
2. Make a copy of `locales/en.po` and rename it with your language code:
   - `fr.po` — French
   - `de.po` — German
   - `it.po` — Italian
   - `pt_BR.po` — Portuguese (Brazil)
   - `ja.po` — Japanese
   - `zh_CN.po` — Simplified Chinese
   - *(and any other language code you'd like!)*
3. Add your translations inside the `msgstr ""` quotes.
4. Submit a **Pull Request** and including in the description at least the following template:

```md
    ### Translation <LANGUAGE_NAME>

    ### Language Details
    - **Language Name**: <LANGUAGE_NAME>
    - **Language Code**: <LANGUAGE_CODE>
    - **Contribution Type**: (select one)
        - [ ] New Translation
        - [ ] Update Existing
    - **Contributor Credit**: @<YOUR_NAME_OR_HANDLE>

    ### Additional Notes
    <ADD_ANY_NOTES_OR_QUESTIONS_HERE... or delete this section if no notes>
```

You can read an example of how this template is filled here:
> https://github.com/KristanLaimon/PanelsPlus/issues/3

---

## Considerations

- We value authentic human translations over word-for-word machine translation slop. Translate the text meaning and ideas naturally as native speakers would read them.

- **Keep It Concise**: E-reader screens have limited space. Try to keep button text and menu options short so they fit on screen cleanly.

    ***As a rule of thumb***: try to make the your text translated length similar to the english text length (length in characters). So it doesn´t overflow in Panels+ UI buttons and menus.

- **Formatting Symbols**:
  - `\n`: Represents a line break. Keep it in your translation where appropriate.
  - `%s` or `%d`: Represents dynamic values (like numbers or mode names). Keep these exact symbols in your translation so the plugin works properly.

---

## 🌐 Supported Language IDs (KOReader Locale Codes)

When naming your `.po` file in `locales/`, use the language code recognized by KOReader (e.g., `locales/<lang_code>.po`). Languages marked with ✅ are already implemented in Panels+; all other languages are open for contributions!

| Status   | Language Name                     | Language Code | `.po` Filename |
|:--------:|:--------------------------------- |:------------- |:-------------- |
| ⌛ Needed | **Afrikaans**                     | `af`          | `af.po`        |
| ⌛ Needed | **Albanian**                      | `sq`          | `sq.po`        |
| ⌛ Needed | **Amharic**                       | `am`          | `am.po`        |
| ⌛ Needed | **Arabic**                        | `ar`          | `ar.po`        |
| ⌛ Needed | **Armenian**                      | `hy`          | `hy.po`        |
| ⌛ Needed | **Assamese**                      | `as`          | `as.po`        |
| ⌛ Needed | **Azerbaijani**                   | `az`          | `az.po`        |
| ⌛ Needed | **Basque**                        | `eu`          | `eu.po`        |
| ⌛ Needed | **Belarusian**                    | `be`          | `be.po`        |
| ⌛ Needed | **Bengali**                       | `bn`          | `bn.po`        |
| ⌛ Needed | **Bosnian**                       | `bs`          | `bs.po`        |
| ⌛ Needed | **Breton**                        | `br`          | `br.po`        |
| ⌛ Needed | **Bulgarian**                     | `bg`          | `bg.po`        |
| ⌛ Needed | **Burmese / Myanmar**             | `my`          | `my.po`        |
| ⌛ Needed | **Catalan / Valencian**           | `ca`          | `ca.po`        |
| ✅        | **Chinese (Simplified)**          | `zh_CN`       | `zh_CN.po`     |
| ⌛ Needed | **Chinese (Traditional, Taiwan)** | `zh_TW`       | `zh_TW.po`     |
| ⌛ Needed | **Chinese (Hong Kong)**           | `zh_HK`       | `zh_HK.po`     |
| ⌛ Needed | **Croatian**                      | `hr`          | `hr.po`        |
| ⌛ Needed | **Czech**                         | `cs`          | `cs.po`        |
| ⌛ Needed | **Danish**                        | `da`          | `da.po`        |
| ⌛ Needed | **Dutch**                         | `nl`          | `nl.po`        |
| ✅        | **English** *(Master template)*   | `en`          | `en.po`        |
| ⌛ Needed | **English (United Kingdom)**      | `en_GB`       | `en_GB.po`     |
| ⌛ Needed | **Esperanto**                     | `eo`          | `eo.po`        |
| ⌛ Needed | **Estonian**                      | `et`          | `et.po`        |
| ⌛ Needed | **Filipino / Tagalog**            | `fil` / `tl`  | `fil.po`       |
| ⌛ Needed | **Finnish**                       | `fi`          | `fi.po`        |
| ⌛ Needed | **French**                        | `fr`          | `fr.po`        |
| ⌛ Needed | **French (Canada)**               | `fr_CA`       | `fr_CA.po`     |
| ⌛ Needed | **Galician**                      | `gl`          | `gl.po`        |
| ⌛ Needed | **Georgian**                      | `ka`          | `ka.po`        |
| ⌛ Needed | **German**                        | `de`          | `de.po`        |
| ⌛ Needed | **German (Austria)**              | `de_AT`       | `de_AT.po`     |
| ⌛ Needed | **German (Switzerland)**          | `de_CH`       | `de_CH.po`     |
| ⌛ Needed | **Greek**                         | `el`          | `el.po`        |
| ⌛ Needed | **Gujarati**                      | `gu`          | `gu.po`        |
| ⌛ Needed | **Haitian Creole**                | `ht`          | `ht.po`        |
| ⌛ Needed | **Hebrew**                        | `he`          | `he.po`        |
| ⌛ Needed | **Hindi**                         | `hi`          | `hi.po`        |
| ⌛ Needed | **Hungarian**                     | `hu`          | `hu.po`        |
| ⌛ Needed | **Icelandic**                     | `is`          | `is.po`        |
| ⌛ Needed | **Indonesian**                    | `id`          | `id.po`        |
| ⌛ Needed | **Irish**                         | `ga`          | `ga.po`        |
| ⌛ Needed | **Italian**                       | `it`          | `it.po`        |
| ⌛ Needed | **Japanese**                      | `ja`          | `ja.po`        |
| ⌛ Needed | **Javanese**                      | `jv`          | `jv.po`        |
| ⌛ Needed | **Kannada**                       | `kn`          | `kn.po`        |
| ⌛ Needed | **Kazakh**                        | `kk`          | `kk.po`        |
| ⌛ Needed | **Khmer**                         | `km`          | `km.po`        |
| ⌛ Needed | **Korean**                        | `ko`          | `ko.po`        |
| ⌛ Needed | **Kurdish**                       | `ku`          | `ku.po`        |
| ⌛ Needed | **Kyrgyz**                        | `ky`          | `ky.po`        |
| ⌛ Needed | **Lao**                           | `lo`          | `lo.po`        |
| ⌛ Needed | **Latin**                         | `la`          | `la.po`        |
| ⌛ Needed | **Latvian**                       | `lv`          | `lv.po`        |
| ⌛ Needed | **Lithuanian**                    | `lt`          | `lt.po`        |
| ⌛ Needed | **Luxembourgish**                 | `lb`          | `lb.po`        |
| ⌛ Needed | **Macedonian**                    | `mk`          | `mk.po`        |
| ⌛ Needed | **Malagasy**                      | `mg`          | `mg.po`        |
| ⌛ Needed | **Malay**                         | `ms`          | `ms.po`        |
| ⌛ Needed | **Malayalam**                     | `ml`          | `ml.po`        |
| ⌛ Needed | **Maltese**                       | `mt`          | `mt.po`        |
| ⌛ Needed | **Marathi**                       | `mr`          | `mr.po`        |
| ⌛ Needed | **Mongolian**                     | `mn`          | `mn.po`        |
| ⌛ Needed | **Nepali**                        | `ne`          | `ne.po`        |
| ⌛ Needed | **Norwegian Bokmål**              | `nb`          | `nb.po`        |
| ⌛ Needed | **Norwegian Nynorsk**             | `nn`          | `nn.po`        |
| ⌛ Needed | **Occitan**                       | `oc`          | `oc.po`        |
| ⌛ Needed | **Odia (Oriya)**                  | `or`          | `or.po`        |
| ⌛ Needed | **Pashto**                        | `ps`          | `ps.po`        |
| ⌛ Needed | **Persian**                       | `fa`          | `fa.po`        |
| ⌛ Needed | **Polish**                        | `pl`          | `pl.po`        |
| ⌛ Needed | **Portuguese (Brazil)**           | `pt_BR`       | `pt_BR.po`     |
| ⌛ Needed | **Portuguese (Portugal)**         | `pt_PT`       | `pt_PT.po`     |
| ⌛ Needed | **Punjabi**                       | `pa`          | `pa.po`        |
| ⌛ Needed | **Romanian**                      | `ro`          | `ro.po`        |
| ⌛ Needed | **Russian**                       | `ru`          | `ru.po`        |
| ⌛ Needed | **Sanskrit**                      | `sa`          | `sa.po`        |
| ⌛ Needed | **Scottish Gaelic**               | `gd`          | `gd.po`        |
| ⌛ Needed | **Serbian (Cyrillic)**            | `sr`          | `sr.po`        |
| ⌛ Needed | **Serbian (Latin)**               | `sr_Latn`     | `sr_Latn.po`   |
| ⌛ Needed | **Sinhala**                       | `si`          | `si.po`        |
| ⌛ Needed | **Slovak**                        | `sk`          | `sk.po`        |
| ⌛ Needed | **Slovenian**                     | `sl`          | `sl.po`        |
| ✅        | **Spanish**                       | `es`          | `es.po`        |
| ⌛ Needed | **Spanish (Latin America)**       | `es_419`      | `es_419.po`    |
| ⌛ Needed | **Sundanese**                     | `su`          | `su.po`        |
| ⌛ Needed | **Swahili**                       | `sw`          | `sw.po`        |
| ⌛ Needed | **Swedish**                       | `sv`          | `sv.po`        |
| ⌛ Needed | **Tajik**                         | `tg`          | `tg.po`        |
| ⌛ Needed | **Tamil**                         | `ta`          | `ta.po`        |
| ⌛ Needed | **Tatar**                         | `tt`          | `tt.po`        |
| ⌛ Needed | **Telugu**                        | `te`          | `te.po`        |
| ⌛ Needed | **Thai**                          | `th`          | `th.po`        |
| ⌛ Needed | **Turkish**                       | `tr`          | `tr.po`        |
| ⌛ Needed | **Turkmen**                       | `tk`          | `tk.po`        |
| ⌛ Needed | **Ukrainian**                     | `uk`          | `uk.po`        |
| ⌛ Needed | **Urdu**                          | `ur`          | `ur.po`        |
| ⌛ Needed | **Uzbek**                         | `uz`          | `uz.po`        |
| ⌛ Needed | **Vietnamese**                    | `vi`          | `vi.po`        |
| ⌛ Needed | **Welsh**                         | `cy`          | `cy.po`        |
| ⌛ Needed | **Yiddish**                       | `yi`          | `yi.po`        |

> 💡 **Note**: If your KOReader language code isn't listed above, Panels+ supports any standard KOReader locale code—simply use the language code KOReader uses as your `.po` filename.

---

Thank you for helping bring Panels+ to readers worldwide.
