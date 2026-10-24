-- AutopilotLive — Фаза 10.2: встроенное радиальное меню (Quick Access)
-- Официальный API: core_quickAccess.addEntry (экспортирован, quickAccess.lua:2753).
-- Вкладка «AutopilotLive» появляется рядом с «Ремонт»/«ИИ» в списке категорий
-- Free roam (/root/sandbox/), внутри — две кнопки с динамическим статусом.

local M = {}
local registered = false

function M.register()
  if registered then return end
  if not core_quickAccess or not core_quickAccess.addEntry then return end

  -- Категория (вкладка) рядом с «Ремонт» / «ИИ»
  core_quickAccess.addEntry({
    level = '/root/sandbox/',
    title = 'AutopilotLive',
    ['goto'] = '/root/sandbox/apl/',
    icon = 'steeringWheelSporty',
    categoryOrder = -40,
    uniqueID = 'aplCategory',
  })

  -- Содержимое вкладки: ТРЕТИЙ уровень (/root/sandbox/apl/) — здесь можно
  -- действия без goto. На втором уровне quickAccess ждёт только категории
  -- с goto (quickAccess.lua:1669), иначе FATAL.
  core_quickAccess.addEntry({
    level = '/root/sandbox/apl/',
    generator = function(entries)
      table.insert(entries, {
        title = 'Живая тачка',
        desc = 'Мастер: прогрев → wheel/pedals/lights/popup/pain → AI',
        icon = 'steeringWheelSporty',
        startSlot = 1,
        uniqueID = 'aplMaster',
        onSelect = function()
          if apl_autopilot then apl_autopilot('toggle') end
          return { 'hide' }
        end
      })
      table.insert(entries, {
        title = 'Погладить',
        desc = 'Звук + мягкий руль + ручник (на стоянке)',
        icon = 'magicWand',
        startSlot = 2,
        uniqueID = 'aplPet',
        onSelect = function()
          if apl_pet then apl_pet('on') end
          return { 'hide' }
        end
      })
    end
  })

  registered = true
  print('apl_quickAccess: вкладка AutopilotLive зарегистрирована (/root/sandbox/apl/)')
end

-- Хук ванили: quickAccess вызывает его при регистрации меню
function M.onRegisterQuickAccessMenus()
  M.register()
end

-- Страховка: если хук уже прошёл до загрузки нашего расширения
function M.onExtensionLoaded()
  M.register()
end

return M
