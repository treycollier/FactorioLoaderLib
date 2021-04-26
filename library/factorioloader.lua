local Loader = {}

require("library/factorioglobals")

JSON = require("externals/JSON") -- needed for the info.json-file

require("lfs")
require("zip")

local CFGParser = require("library/cfgparser")
local SettingLoader = require("library/settingloader")
local ZipModLoader = require("library/ZipModLoader")
local CrossModLoader = require("library/CrossModLoader")
mods = {}

function endswith(s, sub)
    return string.sub(s, -string.len(sub)) == sub
end

--- Loads Factorio data files from a list of mods.
-- executes all module loaders (data.lua),
-- they do some stuff and extend the global variable "data",
-- after calling this function, the function replace_path can be used.
-- @params table paths - list of mods that are loaded.
--    - First one has to be "core"!
function Loader.load_data(game_path, mod_dir)
    local paths = {game_path .. "/data/core", game_path .. "/data/base"}
    local filenames = {"data", "data-updates", "data-final-fixes"}

    local module_info = {}
    local order

    settings = SettingLoader.load(mod_dir .. "/mod-settings.dat")

    local crossModLoader = CrossModLoader.new(module_info)
    table.insert(package.searchers, 1, crossModLoader)

    for i = 1, #paths do
        Loader.addModuleInfo(paths[i], module_info)
    end
    local modlist = Loader.getModList(mod_dir)
    for filename in lfs.dir(mod_dir) do
        local mod_name = string.gsub(filename, "(.+)_[^_]+", "%1")
        if modlist[mod_name] ~= nil then
            if endswith(filename, ".zip") then
                local info = ZipModule.new(mod_dir, string.sub(filename, 1, -5))
                module_info[mod_name] = info
            else
                error("Loading unzipped mods is not supported at the moment.")
            end
        end
    end

    module_info = Loader.moduleInfoCompatibilityPatches(module_info)

    order = Loader.dependenciesOrder(module_info)

    for _, module_name in ipairs(order) do
        mods[module_name] = module_info[module_name].version
    end

    -- load locale data
    local locales = {}
    for _, module_name in ipairs(order) do
        local info = module_info[module_name]
        info:locale(locales)
    end

    -- loop over all order
    local inited = false
    for _, filename in ipairs(filenames) do
        for _, module_name in ipairs(order) do
            local info = module_info[module_name]

            -- special: The core-module has the lualib-dir, which needs to be
            -- added
            if module_name == 'core' and not inited then
                package.path = info.localPath .. "/lualib/?.lua;" .. package.path
                require("dataloader")
                inited = true
            end

            local loaded = {}
            for name, mod in pairs(package.loaded) do
                loaded[name] = mod
            end
            info:run(filename)
            for name, mod in pairs(package.loaded) do
                if loaded[name] == nil then
                    package.loaded[name] = nil
                end
            end
        end
    end

    local new_info = {}
    for _, module_name in pairs(order) do
        new_info[module_name] = module_info[module_name]
    end
    data.raw['module_info'] = new_info
    return locales
end

function showtable(t, indent)
    local k, v
    if indent == nil then
        indent = ""
    end
    for k, v in pairs(t) do
        if type(v) == "table" then
            io.stderr:write(indent .. k .. "\n")
            showtable(v, indent .. "  ")
        else
            io.stderr:write(indent .. k .. "\t" .. tostring(v) .. "\n")
        end
    end
end

function Loader.getModList(mod_dir)
    local f = assert(io.open(mod_dir .. "/mod-list.json"))
    local s = f:read("*a")
    local modlist = JSON:decode(s)
    f:close()
    local i
    local modnames = {}
    for _, mod in pairs(modlist.mods) do
        if mod.enabled and mod.name ~= "base" and mod.name ~= "scenario-pack" then
            modnames[mod.name] = {}
        end
    end
    return modnames
end

local dependency_type = {
    required = 1,
    optional = 2,
    hidden_optional = 3,
    conflict = 4
}

local function string_trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function parse_dependency(dep_string)
    local dependency = {}
    local first_char = string.sub(dep_string, 1, 1)
    local start_idx_name_part
    if first_char == "!" then
        dependency.type = dependency_type.conflict
        start_idx_name_part = 2
    elseif first_char == "?" then
        dependency.type = dependency_type.optional
        start_idx_name_part = 2
    elseif first_char == "(" then
        local prefix_remainder = string.sub(dep_string, 2, 3)
        if prefix_remainder == "?)" then
            dependency.type = dependency_type.hidden_optional
            start_idx_name_part = 4
        else
            error("unable to parse dependency string '" .. dep_string .."'")
        end
    else
        dependency.type = dependency_type.required
        start_idx_name_part = 1
    end

    local start_idx_version_part = string.find(dep_string, "[=><].*")
    local end_idx_name_part = (start_idx_version_part or 0) - 1
    dependency.name = string_trim(string.sub(dep_string, start_idx_name_part, end_idx_name_part))

    return dependency
end

local function build_topology(module_info, module)
    for _, dep_string in pairs(module.dependencies) do
        local parsed_dep = parse_dependency(dep_string)
        local dep_module = module_info[parsed_dep.name]

        if not dep_module and parsed_dep.type == dependency_type.required then
            error("Required depedency '" .. parsed_dep.name .. "' missing.")
        end
        if dep_module and parsed_dep.type == dependency_type.conflict then
            error("Conflicting dependency '" .. parsed_dep.name .. "' present.")
        end

        if dep_module then
            table.insert(dep_module.topology_data.dependants, module.name)
            module.topology_data.dependencies_count = module.topology_data.dependencies_count + 1
        end
    end
end

local function topological_sort(module_info, root_nodes, order)
    local next_level_nodes = {}
    table.sort(root_nodes, function(a, b)
        return string.lower(a) < string.lower(b)
    end)
    for _, node in ipairs(root_nodes) do
        table.insert(order, node)
        for _, dependant in pairs(module_info[node].topology_data.dependants) do
           local topology_data = module_info[dependant].topology_data
           topology_data.dependencies_count = topology_data.dependencies_count - 1
           if topology_data.dependencies_count == 0 then
               table.insert(next_level_nodes, dependant)
           end
        end
    end
    if #next_level_nodes > 0 then
        topological_sort(module_info, next_level_nodes, order)
    end
end

function Loader.dependenciesOrder(module_info)
    for _, module in pairs(module_info) do
        module.topology_data = {
            dependants = {},
            dependencies_count = 0
        }
    end
    for _, module in pairs(module_info) do
        build_topology(module_info, module)
    end
    local order = {}
    -- core is known to be the only root because everything depends on it
    topological_sort(module_info, {"core"}, order)
    return order
end

Module = {}
Module.__index = Module

function Module:load(filename, action)
    filename = string.gsub(filename, "%.", "/")
    action = action or function (f) return f end
    local old_path = package.path
    local file_path = self.localPath .. "/" .. filename .. ".lua"
    local f = io.open(file_path, "r")
    if f ~= nil then
        io.close(f)
    else
        return
    end
    package.path = self.localPath .. "/?.lua;" .. package.path
    local ret = action(assert(loadfile(file_path)))
    package.path = old_path
    return ret
end
function Module:run(filename)
    return self:load(filename, function (f) return f() end)
end
function Module:locale(locales)
    local locale_dir = self.localPath .. "/locale"
    if lfs.attributes(locale_dir, "mode") ~= "directory" then
        return
    end
    for locale in lfs.dir(locale_dir) do
        if locale ~= "." and locale ~= ".." then
            local d = locale_dir .. "/" .. locale
            -- ignore non-directories
            if lfs.attributes(d, "mode") == "directory" then
                local locale_table = locales[locale]
                if locale_table == nil then
                    locale_table = {}
                    locales[locale] = locale_table
                end
                for filename in lfs.dir(d) do
                    if filename ~= "." and filename ~= ".." then
                        if filename:sub(-4):lower() == ".cfg" then
                            local f = assert(io.open(d .. "/" .. filename, "r"))
                            CFGParser.parse(f, locale_table)
                            f:close()
                        end
                    end
                end
            end
        end
    end
end

ZipModule = {}
ZipModule.__index = ZipModule

-- dirname is the Factorio/mods directory.
-- mod_name includes the version number.
function ZipModule.new(dirname, mod_name)
    if string.sub(dirname, -1) ~= "/" then
        dirname = dirname .. "/"
    end
    local filename = dirname .. mod_name .. ".zip"
    local arc = assert(zip.open(filename))
    local arc_subfolder

    for file in arc:files() do
        local idx_start, _ = string.find(file.filename, "info.json", 1, true)
        if idx_start ~= nil then
            arc_subfolder = string.sub(file.filename, 1, idx_start-1)
            break
        end
    end
    local info_filename = arc_subfolder .. "info.json"
    local f = arc:open(info_filename)
    local info = JSON:decode(f:read("*a"))
    info.mod_path = dirname
    info.mod_name = mod_name
    info.zip_path = filename
    info.arc_subfolder = arc_subfolder
    setmetatable(info, ZipModule)
    return info
end
function ZipModule.load(self, filename, action)
    action = action or function (f) return f end
    local loader = ZipModLoader.new(self.mod_path, self.mod_name, self.arc_subfolder)
    table.insert(package.searchers, 2, loader)
    local mod = loader(filename)
    if type(mod) == "string" then
        table.remove(package.searchers, 2)
        loader:close()
        return
    end
    local ret
    if mod ~= nil then ret = action(mod) end
    table.remove(package.searchers, 2)
    loader:close()
    return ret
end
function ZipModule.run(self, filename)
    self.load(self, filename, function (f) return f() end)
end
function ZipModule:locale(locales)
    local arc = assert(zip.open(self.zip_path))
    local pattern = "^" .. self.arc_subfolder .. "locale/([^/]+)/.+%.cfg$"
    for info in arc:files() do
        local locale = info.filename:match(pattern)
        if locale ~= nil then
            local locale_table = locales[locale]
            if locale_table == nil then
                locale_table = {}
                locales[locale] = locale_table
            end
            local f = arc:open(info.filename)
            CFGParser.parse(f, locale_table)
            f:close()
        end
    end
    arc:close()
end

--- add the info.json as to the data-struct, if available
-- converts the json into lua-data
-- adds the localPath to the module info, which is the relative path of the module
function Loader.addModuleInfo(path, module_info)
    local basename = Loader.basename(path)
    local info = JSON:decode(Loader.loadModuleInfo(path))
    setmetatable(info, Module)
    -- add the local path to the struct to keep the source paths in the struct:
    info.localPath = path
    module_info[basename] = info
end

--- add base as a dependency if info.json did not specify a dependencies array
--- add core as a dependency to every other mode to make sure core always loads first
--- add the version information to the core module by searching in the base module
function Loader.moduleInfoCompatibilityPatches(module_info)
    local k, v, version
    for k,v in pairs(module_info) do
        if k ~= "base" and k ~= "core" then
            v.dependencies = v.dependencies or {"base"}
        end
        if k ~= 'core' then
            table.insert(v['dependencies'], 'core')
        end
        if k == 'base' then
            version = v['version']
        end
    end
    if module_info['core'] and version then
        module_info['core']['version'] = version
    end
    return module_info
end

--- read the contents of the module info.json
-- returns in every case a valid json
function Loader.loadModuleInfo(path)
    local infopath = path .. "/info.json"

    assert(Loader.fileExists(infopath), "File not existing: '" .. path .. "/info.json'")

    assert(io.input(path .. "/info.json",
           "\nCannot open the 'info.json' file for '" .. path .. "'"))
    file_content = io.read("*all")
    if file_content then
        return file_content
    end
    return '{}'
end

--- simple check if a file exists
-- @params string path
function Loader.fileExists(path)
    local f=io.open(path, "r")
    if f~=nil then io.close(f) return true else return false end
end

--- basename of path
-- returns the name of the upper directory from path
-- @params string path
-- @return string - the basename
function Loader.basename(path)
    local name = string.gsub(path, "(.*[/\\])(.*)", "%2")
    return name
end

return Loader
