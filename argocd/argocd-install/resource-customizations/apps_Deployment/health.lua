-- json parsing code source: https://gist.github.com/tylerneylon/59f4bcf316be525b30ab
local json = {}

-- Returns pos, did_find; there are two cases:
-- 1. Delimiter found: pos = pos after leading space + delim; did_find = true.
-- 2. Delimiter not found: pos = pos after leading space;     did_find = false.
-- This throws an error if err_if_missing is true and the delim is not found.
local function skip_delim(str, pos, delim, err_if_missing)
    pos = pos + #str:match('^%s*', pos)
    if str:sub(pos, pos) ~= delim then
        if err_if_missing then
            error('Expected ' .. delim .. ' near position ' .. pos)
        end
        return pos, false
    end
    return pos + 1, true
end

-- Expects the given pos to be the first character after the opening quote.
-- Returns val, pos; the returned pos is after the closing quote character.
local function parse_str_val(str, pos, val)
    val = val or ''
    local early_end_error = 'End of input found while parsing string.'
    if pos > #str then
        error(early_end_error)
    end
    local c = str:sub(pos, pos)
    if c == '"' then
        return val, pos + 1
    end
    if c ~= '\\' then
        return parse_str_val(str, pos + 1, val .. c)
    end
    -- We must have a \ character.
    local esc_map = {
        b = '\b',
        f = '\f',
        n = '\n',
        r = '\r',
        t = '\t'
    }
    local nextc = str:sub(pos + 1, pos + 1)
    if not nextc then
        error(early_end_error)
    end
    return parse_str_val(str, pos + 2, val .. (esc_map[nextc] or nextc))
end

-- Returns val, pos; the returned pos is after the number's final character.
local function parse_num_val(str, pos)
    local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    local val = tonumber(num_str)
    if not val then
        error('Error parsing number at position ' .. pos .. '.')
    end
    return val, pos + #num_str
end

json.null = {} -- This is a one-off table to represent the null value.

-- Returns a hash table from a stringified json
function json.parse(str, pos, end_delim)
    pos = pos or 1
    if pos > #str then
        error('Reached unexpected end of input.')
    end
    local pos = pos + #str:match('^%s*', pos) -- Skip whitespace.
    local first = str:sub(pos, pos)
    if first == '{' then -- Parse an object.
        local obj, key, delim_found = {}, true, true
        pos = pos + 1
        while true do
            key, pos = json.parse(str, pos, '}')
            if key == nil then
                return obj, pos
            end
            if not delim_found then
                error('Comma missing between object items.')
            end
            pos = skip_delim(str, pos, ':', true) -- true -> error if missing.
            obj[key], pos = json.parse(str, pos)
            pos, delim_found = skip_delim(str, pos, ',')
        end
    elseif first == '[' then -- Parse an array.
        local arr, val, delim_found = {}, true, true
        pos = pos + 1
        while true do
            val, pos = json.parse(str, pos, ']')
            if val == nil then
                return arr, pos
            end
            if not delim_found then
                error('Comma missing between array items.')
            end
            arr[#arr + 1] = val
            pos, delim_found = skip_delim(str, pos, ',')
        end
    elseif first == '"' then -- Parse a string.
        return parse_str_val(str, pos + 1)
    elseif first == '-' or first:match('%d') then -- Parse a number.
        return parse_num_val(str, pos)
    elseif first == end_delim then -- End of an object or array.
        return nil, pos + 1
    else -- Parse true, false, or null.
        local literals = {
            ['true'] = true,
            ['false'] = false,
            ['null'] = json.null
        }
        for lit_str, lit_val in pairs(literals) do
            local lit_end = pos + #lit_str - 1
            if str:sub(pos, lit_end) == lit_str then
                return lit_val, lit_end + 1
            end
        end
        local pos_info_str = 'position ' .. pos .. ': ' .. str:sub(pos, pos + 10)
        error('Invalid json syntax starting at ' .. pos_info_str)
    end
end

--
-- Actual health check logic starts here
--

local health_check = {}
local status_annotation = "experimental.status.workload.kcp.dev"

local function get_condition(type, status)
    if status.conditions ~= nil then
        for i, condition in pairs(status.conditions) do
            if condition.type == type then
                return condition
            end
        end
    end
    return nil
end

-- Receives the the Deployment and calculates its health
-- based on it. This function is based in the logic of the default
-- ArgoCD health check for Deployments
-- (https://github.com/argoproj/gitops-engine/blob/3951079de1995c4539643b98b200b16eac5eb985/pkg/health/health_deployment.go#L27-L68)
local function deployment_health(dep)

    cond = get_condition("Progressing", dep.status)

    if cond ~= nil and cond.reason ~= "NewReplicaSetAvailable" then
        -- NewReplicaSetAvailable marks a rollout as complete:
        -- (https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#complete-deployment)
        if cond.reason == "ProgressDeadlineExceeded" then
            health_check.status = "Degraded"
            health_check.message = "Deployment " .. dep.metadata.name .. " exceeded its progress deadline"
            return health_check
        elseif dep.status.replicas ~= nil and dep.status.updatedReplicas < dep.spec.replicas then
            health_check.status = "Progressing"
            health_check.message = "Waiting for rollout to finish, " .. dep.status.updatedReplicas .. "/" ..
                                       dep.spec.replicas .. " replicas updated"
            return health_check
        elseif dep.status.replicas ~= nil and dep.status.replicas > dep.status.updatedReplicas then
            health_check.status = "Progressing"
            health_check.message =
                "Waiting for rollout to finish, " .. dep.status.replicas - dep.status.updatedReplicas ..
                    " old replicas are pending termination"
            return health_check
        elseif dep.status.availableReplicas ~= nil and dep.status.availableReplicas < dep.status.updatedReplicas then
            health_check.status = "Progressing"
            health_check.message = "Waiting for rollout to finish, " .. dep.status.availableReplicas .. "/" ..
                                       dep.spec.updatedReplicas .. " updated replicas are available"
            return health_check
        else
            error("unknown rollout status")
        end

    else
        -- no ongoing rollout
        health_check.status = "Healthy"
        health_check.message = ""
        return health_check
    end

end

local function health(obj)

    -- Check if Deployment is paused
    if obj.spec.paused then
        health_check.status = "Suspended"
        health_check.message = "Deployment is paused"
        return health_check
    end

    -- Return health for non kcp Deployments
    if obj.status ~= nil then
        return deployment_health(obj)
    end

    -- Return health for KCP Deployments (status provided by an annotation)
    if obj.metadata.annotations ~= nil then
        for k, v in pairs(obj.metadata.annotations) do
            if string.find(k, status_annotation) and v ~= nil then
                obj.status = json.parse(v)
                return deployment_health(obj)
            end
        end
    end

    -- kcp status annotation still not present
    -- can happen when the Deployment has just been created
    -- and the status annotation is not yet present
    error("status not found")
end

ok, hc = pcall(health, obj)
if ok then
    return hc
else
    print("ERROR:", hc)
    health_check.status = "Unknown"
    health_check.message = hc:gsub(":", "")
    return health_check
end
