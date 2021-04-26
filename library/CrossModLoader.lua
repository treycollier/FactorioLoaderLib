local CrossModLoader = {}
CrossModLoader.__index = CrossModLoader

function CrossModLoader.new(module_info)
    local loader = {
        module_info = module_info
    }
    return setmetatable(loader, CrossModLoader)
end

function CrossModLoader:__call(name)
    for modname, path in string.gmatch(name, "__([_%-%a]+)__[/%.](.*)") do
        local mod = self.module_info[modname]
        return mod:load(path)
    end
end

return CrossModLoader
