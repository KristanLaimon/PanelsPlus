--[[
Page templates: a page saved to start new pages from (a planner, a meeting
sheet). Each is a one-page notebook file in the library's hidden ".templates"
folder, so it travels with the library and opens like any notebook.
Plain Lua, so the headless tests drive it.
]]

local Notebook = require("ink/notebook")
local Project = require("ink/project")
local Storage = require("ink/storage")

local Templates = {}

Templates.DIR = ".templates"

-- The templates folder of library `root`, made if missing (or nil).
function Templates.dir(root)
    local dir = Storage.join(root, Templates.DIR)
    return Storage.ensureDir(dir) and dir or nil
end

-- The template names in library `root`, sorted.
function Templates.list(root)
    local names = {}
    for _, e in ipairs(Storage.list(Storage.join(root, Templates.DIR))) do
        if e.mode == "file" and e.name:sub(1, 1) ~= "." and e.name:lower():match("%." .. Project.EXT .. "$") then
            names[#names + 1] = Storage.stem(e.name)
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- The file of template `name` in library `root`.
function Templates.path(root, name)
    return Storage.join(Storage.join(root, Templates.DIR), Storage.fileName(name, Project.EXT))
end

-- Save `page` as template `name`: its ink and title, on paper `template` (the
-- page's own, from Notebook:pageTemplate), at w x h. Returns ok, err.
function Templates.save(root, name, page, template, w, h)
    if not Templates.dir(root) then return false, "no templates folder" end
    local saved = {}
    for k, v in pairs(template) do saved[k] = v end
    saved.pdf_path = nil   -- a template never depends on an imported PDF
    local nb = Notebook.new(w, h, saved)
    nb.pages[1].ops = Notebook.deepcopy(page.ops or {})
    nb.pages[1].title = page.title
    return Project.saveNotebook(nb, Templates.path(root, name))
end

-- The page of template `name` and the paper style it is on, or nil.
function Templates.load(root, name)
    local data = Project.load(Templates.path(root, name))
    if not (data and Project.isNotebook(data)) then return nil end
    local nb = Notebook.fromData(data)
    return nb.pages[1], nb.template.style
end

function Templates.remove(root, name)
    return os.remove(Templates.path(root, name)) ~= nil
end

return Templates
