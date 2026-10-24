-- soulPilot — Фаза 10.2: встроенное радиальное меню (Quick Access)
-- Официальный API: core_quickAccess.addEntry (экспортирован, quickAccess.lua:2753).
-- Вкладка «soulPilot» появляется рядом с «Ремонт»/«ИИ» в списке категорий
-- Free roam (/root/sandbox/), внутри — три кнопки (мастер, погладить, парковка).

local M = {}
local registered = false

function M.register()
  if registered then return true end
  if not core_quickAccess or not core_quickAccess.addEntry then return false end

  -- Категория (вкладка) рядом с «Ремонт» / «ИИ»
  core_quickAccess.addEntry({
    level = '/root/sandbox/',
    title = 'soulPilot',
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
      table.insert(entries, {
        title = 'Парковка',
        desc = 'Найти место, остановиться, ручник, заглушить двигатель',
        icon = 'parking',
        startSlot = 3,
        uniqueID = 'aplParking',
        onSelect = function()
          if apl_park then apl_park('auto') end
          return { 'hide' }
        end
      })
    end
  })

  registered = true
  print('apl_quickAccess: вкладка soulPilot зарегистрирована (/root/sandbox/apl/)')
  return true
end

-- Глобальный доступ для main.lua (retry, если quickAccess ещё не готов)
function aplQuickAccessRegister()
  return M.register()
end

-- Хук ванили: вызывается ПОСЛЕ построения стандартных меню.
-- Принудительно пере-регистрируем (uniqueID заменяет старые записи).
function M.onRegisterQuickAccessMenus()
  registered = false
  M.register()
end

-- Страховка: если хук уже прошёл до загрузки нашего расширения
function M.onExtensionLoaded()
  M.register()
end

return M
