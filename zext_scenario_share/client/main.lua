-- Scenario Share's screen: /scenarioshare (Director builders). The page (html/) packs and unpacks codes;
-- the server reads scenarios and makes imports. A code goes up in pieces: a big plain message never arrives.

local PART = 7000
local open = false

local function close()
    if not open then return end
    open = false
    SetNuiFocus(false, false)
    exports.whip_core:SetScreenOpen(false)
    SendNUIMessage({ action = 'close' })
end

RegisterCommand('scenarioshare', function()
    if open then return end
    CreateThread(function()
        local data, why = exports.whip_core:Callback('zext_scenario_share:open')
        if type(data) ~= 'table' then
            exports.whip_core:Notify(why or 'Scenario Share is for Director builders', 'error')
            return
        end
        open = true
        exports.whip_core:SetScreenOpen(true)
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'open', data = data })
    end)
end, false)

--- A callback's answer for the page: { ok = true, data } or { ok = false, why }.
local function answer(data, why)
    if data == false or data == nil then return { ok = false, why = why or 'No answer from the server' } end
    return { ok = true, data = data }
end

RegisterNUICallback('close', function(_, cb)
    close()
    cb({ ok = true })
end)

RegisterNUICallback('refresh', function(_, cb)
    CreateThread(function() cb(answer(exports.whip_core:Callback('zext_scenario_share:open'))) end)
end)

RegisterNUICallback('share', function(body, cb)
    CreateThread(function()
        cb(answer(exports.whip_core:Callback('zext_scenario_share:share', tostring(body and body.key or ''), 0)))
    end)
end)

RegisterNUICallback('import', function(body, cb)
    CreateThread(function()
        local code = type(body) == 'table' and type(body.code) == 'string' and body.code or ''
        if code == '' then return cb({ ok = false, why = 'Paste a code first' }) end
        local total = math.ceil(#code / PART)
        for i = 1, total do
            local got, why = exports.whip_core:Callback('zext_scenario_share:part', i, total, code:sub((i - 1) * PART + 1, i * PART))
            if not got then return cb({ ok = false, why = why or 'The code did not all arrive' }) end
        end
        cb(answer(exports.whip_core:Callback('zext_scenario_share:import', type(body.name) == 'string' and body.name or '')))
    end)
end)

RegisterNUICallback('remove', function(body, cb)
    CreateThread(function()
        cb(answer(exports.whip_core:Callback('zext_scenario_share:remove', tostring(body and body.name or ''))))
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and open then SetNuiFocus(false, false) end
end)
