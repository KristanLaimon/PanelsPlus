--[[
Panels+
File: tests/spec/doc_settings_spec.lua
Name: Document settings specs
Description: Verifies per-document setting persistence, restoration, and fallback storage.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for per-document settings persistence (reading mode, navigation mode, crop mode, progress bar).

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert = framework.describe, framework.it, framework.assert

local PanelsPlus = require("main")

local function newPluginInstance(doc_file, doc_settings_mock, global_settings_overrides)
    local plugin = {
        ui = {
            menu = { registerToMainMenu = function() end },
            document = doc_file and { file = doc_file } or nil,
            doc_settings = doc_settings_mock,
        },
        settings = {
            mode = "manga",
            crop_mode = "strict",
            progress_bar_visible = true,
            nav_transition_mode = "classic",
            remember_doc_settings = true,
            doc_settings = {},
        },
        saveSettings = function() end,
        onDispatcherRegisterActions = function() end,
        patchNativePanelZoom = function() end,
        applyNativePanelSetting = function() end,
    }
    for k, v in pairs(global_settings_overrides or {}) do
        plugin.settings[k] = v
    end
    setmetatable(plugin, { __index = PanelsPlus })
    return plugin
end

describe("PanelsPlus per-document settings persistence", function()
    it("saves per-document settings when changing mode, crop mode, progress bar, or nav transition mode", function()
        local doc_store = {}
        local doc_settings_mock = {
            file = "/sdcard/Books/manga_vol1.cbz",
            readSetting = function(_, key)
                return doc_store[key]
            end,
            saveSetting = function(_, key, val)
                doc_store[key] = val
            end,
        }
        local plugin = newPluginInstance("/sdcard/Books/manga_vol1.cbz", doc_settings_mock)

        plugin:setMode("comic")
        plugin:setCropMode("loose")
        plugin:setProgressBarVisible(false)
        plugin:setNavTransitionMode("smooth")

        assert.equals("comic", doc_store.panels_plus.mode)
        assert.equals("loose", doc_store.panels_plus.crop_mode)
        assert.is_false(doc_store.panels_plus.progress_bar_visible)
        assert.equals("smooth", doc_store.panels_plus.nav_transition_mode)
    end)

    it("restores per-document settings when opening a document", function()
        local doc_store = {
            panels_plus = {
                mode = "comic",
                crop_mode = "margin",
                progress_bar_visible = false,
                nav_transition_mode = "animated",
            },
        }
        local doc_settings_mock = {
            file = "/sdcard/Books/comic_vol2.cbr",
            readSetting = function(_, key)
                return doc_store[key]
            end,
            saveSetting = function(_, key, val)
                doc_store[key] = val
            end,
        }
        local plugin = newPluginInstance("/sdcard/Books/comic_vol2.cbr", doc_settings_mock)

        plugin:loadDocSettings()

        assert.equals("comic", plugin.settings.mode)
        assert.equals("margin", plugin.settings.crop_mode)
        assert.is_false(plugin.settings.progress_bar_visible)
        assert.equals("animated", plugin.settings.nav_transition_mode)
    end)

    it("falls back to internal doc_settings dictionary when doc_settings object is unavailable", function()
        local plugin1 = newPluginInstance("/sdcard/Books/doc_a.pdf", nil)
        plugin1:setMode("comic")
        plugin1:setCropMode("none")

        local saved_dict = plugin1.settings.doc_settings
        assert.is_not_nil(saved_dict["/sdcard/Books/doc_a.pdf"])
        assert.equals("comic", saved_dict["/sdcard/Books/doc_a.pdf"].mode)
        assert.equals("none", saved_dict["/sdcard/Books/doc_a.pdf"].crop_mode)

        local plugin2 = newPluginInstance("/sdcard/Books/doc_a.pdf", nil, { doc_settings = saved_dict })
        plugin2:loadDocSettings()

        assert.equals("comic", plugin2.settings.mode)
        assert.equals("none", plugin2.settings.crop_mode)
    end)

    it("does not save or load per-document settings when remember_doc_settings is false", function()
        local doc_store = {
            panels_plus = {
                mode = "comic",
                crop_mode = "margin",
            },
        }
        local doc_settings_mock = {
            file = "/sdcard/Books/manga_vol1.cbz",
            readSetting = function(_, key)
                return doc_store[key]
            end,
            saveSetting = function(_, key, val)
                doc_store[key] = val
            end,
        }
        local plugin = newPluginInstance("/sdcard/Books/manga_vol1.cbz", doc_settings_mock, {
            remember_doc_settings = false,
        })

        plugin:loadDocSettings()
        assert.equals("manga", plugin.settings.mode)
        assert.equals("strict", plugin.settings.crop_mode)

        local doc_store2 = {}
        local doc_settings_mock2 = {
            file = "/sdcard/Books/manga_vol2.cbz",
            readSetting = function(_, key)
                return doc_store2[key]
            end,
            saveSetting = function(_, key, val)
                doc_store2[key] = val
            end,
        }
        plugin.ui.doc_settings = doc_settings_mock2
        plugin:setMode("comic")
        assert.is_nil(doc_store2.panels_plus)
    end)

    it(
        "keeps carried-over settings when opening a new document and does not save until an option is explicitly changed",
        function()
            local doc_store = {}
            local doc_settings_mock = {
                file = "/sdcard/Books/new_doc.cbz",
                readSetting = function(_, key)
                    return doc_store[key]
                end,
                saveSetting = function(_, key, val)
                    doc_store[key] = val
                end,
            }
            local plugin = newPluginInstance("/sdcard/Books/new_doc.cbz", doc_settings_mock, {
                mode = "comic",
                crop_mode = "loose",
            })

            plugin:loadDocSettings()

            assert.equals("comic", plugin.settings.mode)
            assert.equals("loose", plugin.settings.crop_mode)
            assert.is_false(plugin.doc_has_custom_settings)

            plugin:onSaveSettings()
            assert.is_nil(doc_store.panels_plus)

            plugin:setCropMode("margin")

            assert.is_true(plugin.doc_has_custom_settings)
            assert.is_not_nil(doc_store.panels_plus)
            assert.equals("comic", doc_store.panels_plus.mode)
            assert.equals("margin", doc_store.panels_plus.crop_mode)
        end
    )
end)
