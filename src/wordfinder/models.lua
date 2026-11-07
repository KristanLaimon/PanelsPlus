--[[
Panels+
File: src/wordfinder/models.lua
Name: WordFinder
Description: Discovers installed bundled and user OCR models.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
return function(WordFinder)
    -- A distinct language name matters: k2pdfopt caches its engine by language,
    -- not by data directory. Reusing "eng" could silently keep KOReader's model.
    local source = debug.getinfo(1, "S").source:gsub("^@", "")
    local FAST_MODEL_DIR = (source:match("^(.*)[/\\]src[/\\]wordfinder[/\\]models%.lua$") or ".") .. "/data/ocr"
    local BUNDLED_LANGUAGES = { "eng", "spa" }
    local BUNDLED_LANGUAGE_SET = { eng = true, spa = true }

    --- Resolve an installed plugin model without accepting arbitrary path names.
    --- @param language string|nil Three-letter bundled language code.
    --- @return string|nil datadir, string|nil model_language
    function WordFinder.bundledModel(language)
        if not BUNDLED_LANGUAGE_SET[language] then
            return nil
        end
        local model_language = language .. "_fast"
        local model = io.open(FAST_MODEL_DIR .. "/" .. model_language .. ".traineddata", "rb")
        if not model then
            return nil
        end
        model:close()
        return FAST_MODEL_DIR, model_language
    end

    --- Return the bundled models actually present in this plugin package.
    --- @return string[] languages
    function WordFinder.availableBundledLanguages()
        local languages = {}
        for _, language in ipairs(BUNDLED_LANGUAGES) do
            if WordFinder.bundledModel(language) then
                languages[#languages + 1] = language
            end
        end
        return languages
    end

    --- Whether this package contains at least one bundled model.
    --- @return boolean
    function WordFinder.hasBundledData()
        return #WordFinder.availableBundledLanguages() > 0
    end

    --- Find KOReader models installed by the user, including packages without bundled OCR.
    --- The directory is resolved on each open so newly installed files appear immediately.
    function WordFinder.userModelDirectory()
        local ok, storage = pcall(require, "datastorage")
        if ok and storage and storage.getDataDir then
            return storage:getDataDir() .. "/data/tessdata"
        end
        return nil
    end

    function WordFinder.availableUserLanguages()
        local directory = WordFinder.userModelDirectory()
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if not directory or not ok then
            return {}
        end
        local opened, iterator, state = pcall(lfs.dir, directory)
        if not opened or not iterator then
            return {}
        end
        local languages = {}
        for filename in iterator, state do
            local language = filename:match("^([%w_%-]+)%.traineddata$")
            if language and lfs.attributes(directory .. "/" .. filename, "mode") == "file" then
                languages[#languages + 1] = language
            end
        end
        table.sort(languages)
        return languages
    end

    --- Resolve a Panels+ choice to an OCR data directory and engine language.
    --- User selections are restricted to filenames found in KOReader's tessdata.
    function WordFinder.selectedModel(choice)
        if type(choice) ~= "string" then
            return nil
        end
        local user_language = choice:match("^user:([%w_%-]+)$")
        if user_language then
            for _, language in ipairs(WordFinder.availableUserLanguages()) do
                if language == user_language then
                    return WordFinder.userModelDirectory(), language
                end
            end
            return nil
        end
        return WordFinder.bundledModel(choice)
    end
end
