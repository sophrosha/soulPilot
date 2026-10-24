<template>
  <div class="apl-shell">
    <aside class="apl-sidebar">
      <div class="apl-brand">
        <span class="apl-brand-mark">APL</span>
        <div>
          <strong>{{ t("apl.ui.title") }}</strong>
          <small>{{ t("apl.ui.subtitle") }}</small>
        </div>
      </div>

      <nav class="apl-nav">
        <button
          v-for="item in nav"
          :key="item.id"
          class="apl-nav-item"
          :class="{ active: activeSection === item.id }"
          @click="goTo(item.id)"
        >
          <BngIcon :type="item.icon" class="apl-nav-icon" />
          <span>{{ t(item.label) }}</span>
        </button>
      </nav>

      <div class="apl-sidebar-bottom">
        <label class="apl-language">
          <span>{{ t("apl.ui.language") }}</span>
          <select v-model="lang" class="apl-language-select" @change="changeLanguage">
            <option v-for="item in languages" :key="item.id" :value="item.id">{{ item.label }}</option>
          </select>
        </label>
        <div class="apl-version">AutopilotLive · 12.3</div>
      </div>
    </aside>

    <section class="apl-main">
      <header class="apl-topbar">
        <div>
          <h1>{{ t("apl.ui.title") }}</h1>
          <p>{{ t("apl.ui.subtitle") }}</p>
        </div>
        <div class="apl-mode">
          <button
            class="apl-mode-btn"
            :class="{ active: mode === 'normal' }"
            @click="mode = 'normal'"
          >
            {{ t("apl.ui.normal") }}
          </button>
          <button
            class="apl-mode-btn"
            :class="{ active: mode === 'expert' }"
            @click="mode = 'expert'"
          >
            {{ t("apl.ui.expert") }}
          </button>
        </div>
      </header>

      <div ref="scrollArea" class="apl-scroll">
        <div v-if="loading" class="apl-empty">{{ t("apl.ui.loading") }}</div>

        <template v-else>
          <section id="general" class="apl-group">
            <h2 class="apl-group-title">{{ t("apl.ui.general") }}</h2>
            <div class="apl-group-frame">
              <div class="apl-row">
                <div class="apl-row-label">
                  <span>{{ t("apl.modules.master") }}</span>
                  <small>{{ t("apl.modules.master.desc") }}</small>
                </div>
                <button
                  class="apl-toggle"
                  :class="{ on: moduleState.master }"
                  @click="toggleModule('master')"
                >
                  <span class="apl-toggle-knob"></span>
                </button>
              </div>

              <div class="apl-row">
                <div class="apl-row-label">
                  <span>{{ t("apl.modules.lights") }}</span>
                  <small>{{ t("apl.modules.lights.desc") }}</small>
                </div>
                <button
                  class="apl-toggle"
                  :class="{ on: moduleState.lights }"
                  @click="toggleModule('lights')"
                >
                  <span class="apl-toggle-knob"></span>
                </button>
              </div>

              <div class="apl-row">
                <div class="apl-row-label">
                  <span>{{ t("apl.modules.music") }}</span>
                  <small>{{ t("apl.modules.music.desc") }}</small>
                </div>
                <button
                  class="apl-toggle"
                  :class="{ on: moduleState.music }"
                  @click="toggleModule('music')"
                >
                  <span class="apl-toggle-knob"></span>
                </button>
              </div>

              <div class="apl-row">
                <div class="apl-row-label">
                  <span>{{ t("apl.modules.parking") }}</span>
                  <small>{{ t("apl.modules.parking.desc") }}</small>
                </div>
                <button
                  class="apl-toggle"
                  :class="{ on: moduleState.parking }"
                  @click="toggleModule('parking')"
                >
                  <span class="apl-toggle-knob"></span>
                </button>
              </div>
            </div>
          </section>

          <section id="steering" class="apl-group">
            <h2 class="apl-group-title">{{ t("apl.ui.steering") }}</h2>
            <div class="apl-group-frame">
              <div class="apl-row">
                <div class="apl-row-label">
                  <span>{{ t("apl.ui.profile") }}</span>
                  <small>{{ t("apl.modules.wheel.desc") }}</small>
                </div>
                <div class="apl-cycle">
                  <button class="apl-cycle-arrow" @click="cycleProfile(-1)">‹</button>
                  <span class="apl-cycle-value">{{ t(profileLabel) }}</span>
                  <button class="apl-cycle-arrow" @click="cycleProfile(1)">›</button>
                </div>
              </div>

              <template v-if="mode === 'expert'">
                <div v-for="f in expert.steering" :key="f.path" class="apl-row">
                  <div class="apl-row-label">
                    <span>{{ t(f.label) }}</span>
                    <small>{{ f.hint ? t(f.hint) : "" }}</small>
                  </div>
                  <div class="apl-slider-cell">
                    <input
                      class="apl-range"
                      type="range"
                      :min="f.min"
                      :max="f.max"
                      :step="f.step"
                      :value="getVal(f.file, f.path)"
                      @input="setVal(f.file, f.path, $event.target.value)"
                    />
                    <input
                      class="apl-number"
                      type="number"
                      :min="f.min"
                      :max="f.max"
                      :step="f.step"
                      :value="getVal(f.file, f.path)"
                      @change="setVal(f.file, f.path, $event.target.value)"
                    />
                  </div>
                </div>
              </template>
            </div>
          </section>

          <section id="music" class="apl-group">
            <h2 class="apl-group-title">{{ t("apl.ui.music") }}</h2>
            <div class="apl-group-frame">
              <div class="apl-row">
                <div class="apl-row-label">
                  <span>{{ t("apl.modules.music") }}</span>
                  <small>{{ t("apl.modules.music.desc") }}</small>
                </div>
                <button
                  class="apl-toggle"
                  :class="{ on: moduleState.music }"
                  @click="toggleModule('music')"
                >
                  <span class="apl-toggle-knob"></span>
                </button>
              </div>

              <template v-if="mode === 'expert'">
                <div v-for="f in expert.music" :key="f.path" class="apl-row">
                  <div class="apl-row-label">
                    <span>{{ t(f.label) }}</span>
                    <small>{{ f.hint ? t(f.hint) : "" }}</small>
                  </div>
                  <div class="apl-slider-cell">
                    <input
                      class="apl-range"
                      type="range"
                      :min="f.min"
                      :max="f.max"
                      :step="f.step"
                      :value="getVal(f.file, f.path)"
                      @input="setVal(f.file, f.path, $event.target.value)"
                    />
                    <input
                      class="apl-number"
                      type="number"
                      :min="f.min"
                      :max="f.max"
                      :step="f.step"
                      :value="getVal(f.file, f.path)"
                      @change="setVal(f.file, f.path, $event.target.value)"
                    />
                  </div>
                </div>
              </template>
            </div>
          </section>

          <section id="parking" class="apl-group">
            <h2 class="apl-group-title">{{ t("apl.ui.parking") }}</h2>
            <div class="apl-group-frame">
              <div class="apl-row">
                <div class="apl-row-label">
                  <span>{{ t("apl.modules.parking") }}</span>
                  <small>{{ t("apl.modules.parking.desc") }}</small>
                </div>
                <button
                  class="apl-toggle"
                  :class="{ on: moduleState.parking }"
                  @click="toggleModule('parking')"
                >
                  <span class="apl-toggle-knob"></span>
                </button>
              </div>

              <template v-if="mode === 'expert'">
                <div v-for="f in expert.parking" :key="f.path" class="apl-row">
                  <div class="apl-row-label">
                    <span>{{ t(f.label) }}</span>
                  </div>
                  <div class="apl-slider-cell">
                    <input
                      class="apl-range"
                      type="range"
                      :min="f.min"
                      :max="f.max"
                      :step="f.step"
                      :value="getVal(f.file, f.path)"
                      @input="setVal(f.file, f.path, $event.target.value)"
                    />
                    <input
                      class="apl-number"
                      type="number"
                      :min="f.min"
                      :max="f.max"
                      :step="f.step"
                      :value="getVal(f.file, f.path)"
                      @change="setVal(f.file, f.path, $event.target.value)"
                    />
                  </div>
                </div>
              </template>
            </div>
          </section>

          <section id="debug" class="apl-group">
            <h2 class="apl-group-title">{{ t("apl.ui.debug") }}</h2>
            <div class="apl-group-frame">
              <div class="apl-row">
                <div class="apl-row-label">
                  <span>{{ t("apl.ui.debugLogging") }}</span>
                  <small>{{ t("apl.ui.debugLogging.desc") }}</small>
                </div>
                <button
                  class="apl-toggle"
                  :class="{ on: debugEnabled }"
                  @click="toggleDebug"
                >
                  <span class="apl-toggle-knob"></span>
                </button>
              </div>
            </div>
          </section>

          <section id="about" class="apl-group">
            <h2 class="apl-group-title">{{ t("apl.ui.about") }}</h2>
            <div class="apl-group-frame apl-about">
              <p>{{ t("apl.ui.aboutText") }}</p>
              <img
                class="apl-preview"
                src="/ui/modules/apps/AutopilotLive/apl_preview_ui.png"
                alt="AutopilotLive preview"
              />
            </div>
          </section>
        </template>
      </div>

      <footer class="apl-footer">
        <div class="apl-message">
          <span v-if="error" class="apl-error">{{ error }}</span>
          <span v-else-if="messageKey">{{ t(messageKey) }}</span>
        </div>
        <div class="apl-footer-actions">
          <button class="apl-btn secondary" @click="refresh">{{ t("apl.ui.refresh") }}</button>
          <button class="apl-btn primary" @click="save">{{ t("apl.ui.save") }}</button>
        </div>
      </footer>
    </section>
  </div>
</template>

<script setup>
import { onMounted, reactive, ref } from "vue"
import { BngIcon } from "@/common/components/base"
import { useBridge } from "@/bridge"

const { api } = useBridge()

const MESSAGES = {
  "en": {
    "ui.apps.apl.name": "AutopilotLive",
    "ui.apps.apl.description": "AutopilotLive settings: master, lights, music, parking.",
    "apl.ui.title": "AutopilotLive",
    "apl.ui.subtitle": "Driving assistant settings",
    "apl.ui.normal": "Normal",
    "apl.ui.expert": "Expert",
    "apl.ui.overview": "Overview",
    "apl.ui.general": "General",
    "apl.ui.steering": "Steering",
    "apl.ui.profile": "Steering profile",
    "apl.ui.music": "Music",
    "apl.ui.wheel": "Steering",
    "apl.ui.parking": "Parking",
    "apl.ui.debug": "Debug",
    "apl.ui.debugLogging": "Debug Logging",
    "apl.ui.debugLogging.desc": "Print detailed vehicle diagnostics to the console.",
    "apl.ui.language": "Language",
    "apl.ui.about": "About",
    "apl.ui.state": "State",
    "apl.ui.loading": "Loading...",
    "apl.ui.save": "Save",
    "apl.ui.refresh": "Refresh",
    "apl.ui.saved": "Saved",
    "apl.ui.noChanges": "No changes",
    "apl.ui.requiresRespawn": "Saved. Respawn the vehicle to apply wheel settings.",
    "apl.ui.error": "Error",
    "apl.ui.aboutText": "AutopilotLive control panel. Normal mode - simple switches; Expert mode - fine tuning.",
    "apl.ui.expertHint": "Expert changes are saved to ai/config and may require a vehicle respawn.",
    "apl.modules.master": "Master",
    "apl.modules.master.desc": "Warmup, wheel, pedals, lights, popup, pain and AI traffic.",
    "apl.modules.lights": "Lights",
    "apl.modules.lights.desc": "Automatic day/night headlights.",
    "apl.modules.music": "Music",
    "apl.modules.music.desc": "Bass-reactive steering from Spotify via VB-Cable.",
    "apl.modules.parking": "Parking",
    "apl.modules.parking.desc": "Find a parking spot, stop, engage brake and switch the engine off.",
    "apl.modules.wheel": "Steering",
    "apl.modules.wheel.desc": "AI steering smoothing pipeline.",
    "apl.fields.sway_amp": "Parking sway amplitude",
    "apl.fields.vibration_amp": "Driving vibration amplitude",
    "apl.fields.beat_amp": "Beat kick amplitude",
    "apl.fields.beat_decay_s": "Beat decay (s)",
    "apl.fields.vibration_hz": "Vibration frequency (Hz)",
    "apl.fields.steer_rise": "Steering rise rate",
    "apl.fields.steer_fall": "Steering fall rate",
    "apl.fields.ema_tau": "Steering EMA (s)",
    "apl.fields.lerp_tau": "Steering lerp (s)",
    "apl.fields.route_speed": "Parking route speed (m/s)",
    "apl.fields.arrival_radius": "Arrival radius (m)",
    "apl.fields.stop_speed": "Stop speed (m/s)",
    "apl.profile.comfort": "Comfort",
    "apl.profile.sport": "Sport",
    "apl.profile.custom": "Custom"
  },
  "ru": {
    "ui.apps.apl.name": "AutopilotLive",
    "ui.apps.apl.description": "Настройки AutopilotLive: мастер, фары, музыка, паркинг.",
    "apl.ui.title": "AutopilotLive",
    "apl.ui.subtitle": "Настройки помощника вождения",
    "apl.ui.normal": "Обычный",
    "apl.ui.expert": "Эксперт",
    "apl.ui.overview": "Обзор",
    "apl.ui.general": "Основное",
    "apl.ui.steering": "Руль",
    "apl.ui.profile": "Профиль руля",
    "apl.ui.music": "Музыка",
    "apl.ui.wheel": "Руль",
    "apl.ui.parking": "Паркинг",
    "apl.ui.debug": "Отладка",
    "apl.ui.debugLogging": "Логирование отладки",
    "apl.ui.debugLogging.desc": "Печатать подробную диагностику vehicle-слоя в консоль.",
    "apl.ui.language": "Язык",
    "apl.ui.about": "О программе",
    "apl.ui.state": "Состояние",
    "apl.ui.loading": "Загрузка...",
    "apl.ui.save": "Сохранить",
    "apl.ui.refresh": "Обновить",
    "apl.ui.saved": "Сохранено",
    "apl.ui.noChanges": "Изменений нет",
    "apl.ui.requiresRespawn": "Сохранено. Для применения настроек руля переспавните машину.",
    "apl.ui.error": "Ошибка",
    "apl.ui.aboutText": "Панель управления AutopilotLive. Обычный режим — простые переключатели, Эксперт — тонкая настройка.",
    "apl.ui.expertHint": "Изменения эксперта сохраняются в ai/config и могут требовать переспавна машины.",
    "apl.modules.master": "Мастер",
    "apl.modules.master.desc": "Прогрев, руль, педали, фары, popup, боль и AI-трафик.",
    "apl.modules.lights": "Фары",
    "apl.modules.lights.desc": "Автоматические фары день/ночь.",
    "apl.modules.music": "Музыка",
    "apl.modules.music.desc": "Реакция руля на бас из Spotify через VB-Cable.",
    "apl.modules.parking": "Паркинг",
    "apl.modules.parking.desc": "Найти место, остановиться, включить ручник и заглушить двигатель.",
    "apl.modules.wheel": "Руль",
    "apl.modules.wheel.desc": "Конвейер сглаживания руля AI.",
    "apl.fields.sway_amp": "Амплитуда качка на стоянке",
    "apl.fields.vibration_amp": "Амплитуда вибрации в движении",
    "apl.fields.beat_amp": "Амплитуда толчка на beat",
    "apl.fields.beat_decay_s": "Затухание beat (с)",
    "apl.fields.vibration_hz": "Частота вибрации (Гц)",
    "apl.fields.steer_rise": "Скорость руля к упору",
    "apl.fields.steer_fall": "Скорость руля к центру",
    "apl.fields.ema_tau": "Инерция руля EMA (с)",
    "apl.fields.lerp_tau": "Дотягивание руля (с)",
    "apl.fields.route_speed": "Скорость маршрута паркинга (м/с)",
    "apl.fields.arrival_radius": "Радиус прибытия (м)",
    "apl.fields.stop_speed": "Скорость остановки (м/с)",
    "apl.profile.comfort": "Комфорт",
    "apl.profile.sport": "Спорт",
    "apl.profile.custom": "Свой"
  },
  "uk": {
    "ui.apps.apl.name": "AutopilotLive",
    "ui.apps.apl.description": "Налаштування AutopilotLive: майстер, фари, музика, паркування.",
    "apl.ui.title": "AutopilotLive",
    "apl.ui.subtitle": "Налаштування помічника водіння",
    "apl.ui.normal": "Звичайний",
    "apl.ui.expert": "Експерт",
    "apl.ui.overview": "Огляд",
    "apl.ui.general": "Основне",
    "apl.ui.steering": "Кермо",
    "apl.ui.profile": "Профіль керма",
    "apl.ui.music": "Музика",
    "apl.ui.wheel": "Кермо",
    "apl.ui.parking": "Паркування",
    "apl.ui.debug": "Налагодження",
    "apl.ui.debugLogging": "Логування налагодження",
    "apl.ui.debugLogging.desc": "Друкувати докладну діагностику vehicle-шару в консоль.",
    "apl.ui.language": "Мова",
    "apl.ui.about": "Про програму",
    "apl.ui.state": "Стан",
    "apl.ui.loading": "Завантаження...",
    "apl.ui.save": "Зберегти",
    "apl.ui.refresh": "Оновити",
    "apl.ui.saved": "Збережено",
    "apl.ui.noChanges": "Змін немає",
    "apl.ui.requiresRespawn": "Збережено. Для застосування налаштувань керма переспавніть авто.",
    "apl.ui.error": "Помилка",
    "apl.ui.aboutText": "Панель керування AutopilotLive. Звичайний режим — прості перемикачі, Експерт — тонке налаштування.",
    "apl.ui.expertHint": "Зміни експерта зберігаються в ai/config і можуть потребувати переспавну авто.",
    "apl.modules.master": "Майстер",
    "apl.modules.master.desc": "Прогрів, кермо, педалі, фари, popup, біль і AI-трафік.",
    "apl.modules.lights": "Фари",
    "apl.modules.lights.desc": "Автоматичні фари день/ніч.",
    "apl.modules.music": "Музика",
    "apl.modules.music.desc": "Реакція керма на бас зі Spotify через VB-Cable.",
    "apl.modules.parking": "Паркування",
    "apl.modules.parking.desc": "Знайти місце, зупинитися, увімкнути ручник і заглушити двигун.",
    "apl.modules.wheel": "Кермо",
    "apl.modules.wheel.desc": "Конвеєр згладжування керма AI.",
    "apl.fields.sway_amp": "Амплітуда похитування на стоянці",
    "apl.fields.vibration_amp": "Амплітуда вібрації в русі",
    "apl.fields.beat_amp": "Амплітуда поштовху на beat",
    "apl.fields.beat_decay_s": "Затухання beat (с)",
    "apl.fields.vibration_hz": "Частота вібрації (Гц)",
    "apl.fields.steer_rise": "Швидкість керма до упору",
    "apl.fields.steer_fall": "Швидкість керма до центру",
    "apl.fields.ema_tau": "Інерція керма EMA (с)",
    "apl.fields.lerp_tau": "Дотягування керма (с)",
    "apl.fields.route_speed": "Швидкість маршруту паркування (м/с)",
    "apl.fields.arrival_radius": "Радіус прибуття (м)",
    "apl.fields.stop_speed": "Швидкість зупинки (м/с)",
    "apl.profile.comfort": "Комфорт",
    "apl.profile.sport": "Спорт",
    "apl.profile.custom": "Свій"
  },
  "by": {
    "ui.apps.apl.name": "AutopilotLive",
    "ui.apps.apl.description": "Налады AutopilotLive: майстар, фары, музыка, паркоўка.",
    "apl.ui.title": "AutopilotLive",
    "apl.ui.subtitle": "Налады памочніка кіравання",
    "apl.ui.normal": "Звычайны",
    "apl.ui.expert": "Эксперт",
    "apl.ui.overview": "Агляд",
    "apl.ui.general": "Асноўнае",
    "apl.ui.steering": "Руль",
    "apl.ui.profile": "Профіль руля",
    "apl.ui.music": "Музыка",
    "apl.ui.wheel": "Руль",
    "apl.ui.parking": "Паркоўка",
    "apl.ui.debug": "Адладка",
    "apl.ui.debugLogging": "Лагаванне адладкі",
    "apl.ui.debugLogging.desc": "Друкаваць падрабязную дыягностыку vehicle-слоя ў кансоль.",
    "apl.ui.language": "Мова",
    "apl.ui.about": "Пра праграму",
    "apl.ui.state": "Стан",
    "apl.ui.loading": "Загрузка...",
    "apl.ui.save": "Захаваць",
    "apl.ui.refresh": "Абнавіць",
    "apl.ui.saved": "Захавана",
    "apl.ui.noChanges": "Змен няма",
    "apl.ui.requiresRespawn": "Захавана. Для прымянення налад руля пераспаўніце машыну.",
    "apl.ui.error": "Памылка",
    "apl.ui.aboutText": "Панэль кіравання AutopilotLive. Звычайны рэжым — простыя пераключальнікі, Эксперт — тонкая наладка.",
    "apl.ui.expertHint": "Змены эксперта захоўваюцца ў ai/config і могуць патрабаваць пераспаўну машыны.",
    "apl.modules.master": "Майстар",
    "apl.modules.master.desc": "Прагрэў, руль, педалі, фары, popup, боль і AI-трафік.",
    "apl.modules.lights": "Фары",
    "apl.modules.lights.desc": "Аўтаматычныя фары дзень/ноч.",
    "apl.modules.music": "Музыка",
    "apl.modules.music.desc": "Рэакцыя руля на бас са Spotify праз VB-Cable.",
    "apl.modules.parking": "Паркоўка",
    "apl.modules.parking.desc": "Знайсці месца, спыніцца, уключыць ручнік і заглушыць рухавік.",
    "apl.modules.wheel": "Руль",
    "apl.modules.wheel.desc": "Канвеер згладжвання руля AI.",
    "apl.fields.sway_amp": "Амплітуда гайдання на стаянцы",
    "apl.fields.vibration_amp": "Амплітуда вібрацыі ў руху",
    "apl.fields.beat_amp": "Амплітуда штуршка на beat",
    "apl.fields.beat_decay_s": "Затуханне beat (с)",
    "apl.fields.vibration_hz": "Частата вібрацыі (Гц)",
    "apl.fields.steer_rise": "Хуткасць руля да ўпору",
    "apl.fields.steer_fall": "Хуткасць руля да цэнтра",
    "apl.fields.ema_tau": "Інерцыя руля EMA (с)",
    "apl.fields.lerp_tau": "Дотягванне руля (с)",
    "apl.fields.route_speed": "Хуткасць маршруту паркоўкі (м/с)",
    "apl.fields.arrival_radius": "Радыус прыбыцця (м)",
    "apl.fields.stop_speed": "Хуткасць прыпынку (м/с)",
    "apl.profile.comfort": "Камфорт",
    "apl.profile.sport": "Спорт",
    "apl.profile.custom": "Свой"
  }
}

const scrollArea = ref(null)
const lang = ref("en")
const languages = [
  { id: "ru", label: "RU" },
  { id: "en", label: "EN" },
  { id: "uk", label: "UK" },
  { id: "by", label: "BY" },
]

function normalizeLang(value) {
  const raw = String(value || "").toLowerCase().replace(/-/g, "_")
  if (raw.includes("uk") || raw.includes("ua")) return "uk"
  if (raw.startsWith("be") || raw.includes("by")) return "by"
  if (raw.includes("ru")) return "ru"
  return "en"
}

function t(key) {
  const table = MESSAGES[lang.value] || MESSAGES.en
  return table[key] || MESSAGES.en[key] || key
}
const activeSection = ref("general")
const loading = ref(true)
const mode = ref("normal")
const error = ref("")
const messageKey = ref("")
const debugEnabled = ref(false)

const nav = [
  { id: "general", label: "apl.ui.general", icon: "cogOutline" },
  { id: "steering", label: "apl.ui.steering", icon: "steeringWheelSporty" },
  { id: "music", label: "apl.ui.music", icon: "music" },
  { id: "parking", label: "apl.ui.parking", icon: "parking" },
  { id: "debug", label: "apl.ui.debug", icon: "bug" },
  { id: "about", label: "apl.ui.about", icon: "info" },
]

const state = reactive({
  values: {},
  status: {},
  dirty: {},
})

const moduleState = reactive({
  master: false,
  lights: false,
  music: false,
  parking: false,
})

const profileLabels = {
  comfort: "apl.profile.comfort",
  sport: "apl.profile.sport",
  custom: "apl.profile.custom",
}
const profileOrder = ["comfort", "sport", "custom"]
const profileLabel = ref("apl.profile.comfort")

const expert = {
  steering: [
    { file: "wheel", path: "rate_limit.steer_rise", label: "apl.fields.steer_rise", min: 1, max: 20, step: 0.1 },
    { file: "wheel", path: "rate_limit.steer_fall", label: "apl.fields.steer_fall", min: 1, max: 20, step: 0.1 },
    { file: "wheel", path: "ema_tau.steer", label: "apl.fields.ema_tau", min: 0.01, max: 0.5, step: 0.01 },
    { file: "wheel", path: "lerp_tau.steer", label: "apl.fields.lerp_tau", min: 0.01, max: 0.5, step: 0.01 },
  ],
  music: [
    { file: "music", path: "sway_amp", label: "apl.fields.sway_amp", min: 0, max: 0.05, step: 0.001 },
    { file: "music", path: "vibration_amp", label: "apl.fields.vibration_amp", min: 0, max: 0.01, step: 0.0005 },
    { file: "music", path: "beat_amp", label: "apl.fields.beat_amp", min: 0, max: 0.05, step: 0.001 },
    { file: "music", path: "beat_decay_s", label: "apl.fields.beat_decay_s", min: 0.02, max: 1, step: 0.01 },
    { file: "music", path: "vibration_hz", label: "apl.fields.vibration_hz", min: 1, max: 15, step: 0.5 },
  ],
  parking: [
    { file: "parking", path: "route_speed_mps", label: "apl.fields.route_speed", min: 1, max: 20, step: 0.5 },
    { file: "parking", path: "arrival_radius_m", label: "apl.fields.arrival_radius", min: 3, max: 50, step: 1 },
    { file: "parking", path: "stop_speed_mps", label: "apl.fields.stop_speed", min: 0.1, max: 2, step: 0.05 },
  ],
}

function applyStatus(status) {
  if (!status) return
  moduleState.master = status.master === true || status.master === 1 || status.master === "on"
  moduleState.lights = status.lights === true
  moduleState.music = status.music === true
  moduleState.parking = status.parking === true
  debugEnabled.value = status.debug === true
  if (status.language) lang.value = normalizeLang(status.language)
}

function changeLanguage() {
  error.value = ""
  messageKey.value = ""
  api.engineLua(
    `extensions.autopilotLive_uiConfig.setLanguage(${JSON.stringify(lang.value)})`,
    result => {
      if (!result || result.ok === false) {
        error.value = (result && result.error) || "Unable to save language"
        return
      }
      if (result.state) applyStatus(result.state)
      messageKey.value = "apl.ui.saved"
    },
  )
}

function refresh() {
  loading.value = true
  error.value = ""
  api.engineLua("extensions.autopilotLive_uiConfig.getConfig()", data => {
    loading.value = false
    if (!data || !data.values) {
      error.value = "AutopilotLive UI config not available"
      return
    }
    state.values = data.values
    state.status = data.state || {}
    state.dirty = {}
    messageKey.value = ""
    applyStatus(state.status)
    updateProfileLabel()
  })
}

function updateProfileLabel() {
  const wheel = state.values.wheel || {}
  const profile = profileLabels[wheel.mode] ? wheel.mode : "comfort"
  profileLabel.value = profileLabels[profile]
}

function goTo(id) {
  activeSection.value = id
  const root = scrollArea.value
  if (!root) return
  const element = root.querySelector(`#${id}`)
  if (element) {
    element.scrollIntoView({ block: "start", behavior: "smooth" })
  }
}

function toggleModule(id) {
  const next = !moduleState[id]
  moduleState[id] = next
  error.value = ""
  messageKey.value = ""
  api.engineLua(
    `extensions.autopilotLive_uiConfig.setModule(${JSON.stringify(id)}, ${next ? "true" : "false"})`,
    result => {
      if (!result || result.ok === false) {
        moduleState[id] = !next
        error.value = (result && result.error) || "Unable to change module"
        return
      }
      if (result.state) {
        state.status = result.state
        applyStatus(result.state)
      }
      messageKey.value = "apl.ui.saved"
    },
  )
}

function cycleProfile(direction) {
  const wheel = state.values.wheel || (state.values.wheel = {})
  const current = profileOrder.indexOf(wheel.mode || "comfort")
  const next = (current + (direction > 0 ? 1 : -1) + profileOrder.length) % profileOrder.length
  wheel.mode = profileOrder[next]
  state.dirty.wheel = true
  updateProfileLabel()
  messageKey.value = ""
}

function getVal(file, path) {
  let node = state.values[file]
  if (!node) return 0
  for (const part of path.split(".")) {
    if (!node || typeof node !== "object") return 0
    node = node[part]
  }
  return typeof node === "number" ? node : 0
}

function setVal(file, path, value) {
  const number = Number(value)
  if (!Number.isFinite(number)) return
  if (!state.values[file]) state.values[file] = {}
  let node = state.values[file]
  const parts = path.split(".")
  for (let i = 0; i < parts.length - 1; i++) {
    const part = parts[i]
    if (!node[part] || typeof node[part] !== "object") node[part] = {}
    node = node[part]
  }
  node[parts[parts.length - 1]] = number
  state.dirty[file] = true
  messageKey.value = ""
}

function toggleDebug() {
  const next = !debugEnabled.value
  debugEnabled.value = next
  api.engineLua(
    `extensions.autopilotLive_uiConfig.setDebug(${next ? "true" : "false"})`,
    result => {
      if (!result || result.ok === false) {
        debugEnabled.value = !next
        error.value = (result && result.error) || "Unable to change debug mode"
        return
      }
      messageKey.value = "apl.ui.saved"
    },
  )
}

function save() {
  const files = {}
  for (const file of Object.keys(state.dirty)) {
    if (state.dirty[file]) files[file] = state.values[file]
  }
  if (Object.keys(files).length === 0) {
    messageKey.value = "apl.ui.noChanges"
    return
  }
  error.value = ""
  api.engineLua(
    `extensions.autopilotLive_uiConfig.setConfig(${api.serializeToLua({ files })})`,
    result => {
      if (!result || result.ok === false) {
        error.value = (result && result.error) || "Save failed"
        return
      }
      state.dirty = {}
      messageKey.value = result.requiresRespawn ? "apl.ui.requiresRespawn" : "apl.ui.saved"
    },
  )
}

onMounted(refresh)
</script>

<style scoped lang="scss">
.apl-shell {
  --apl-bg: #141619;
  --apl-panel: #1a1d21;
  --apl-panel-2: #20242a;
  --apl-line: #2d3239;
  --apl-text: #e6e8ea;
  --apl-muted: #979da4;
  --apl-accent: #ff8a1f;

  display: flex;
  width: 100%;
  height: 100%;
  overflow: hidden;
  color: var(--apl-text);
  background: var(--apl-bg);
  border: 1px solid var(--apl-line);
  border-radius: 10px;
  font-family: var(--fnt-defs, "Segoe UI", sans-serif);
}

.apl-sidebar {
  width: 220px;
  flex: 0 0 220px;
  display: flex;
  flex-direction: column;
  padding: 20px 12px 14px;
  background: #17191c;
  border-right: 1px solid var(--apl-line);
}

.apl-brand {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 0 10px 18px;
  border-bottom: 1px solid var(--apl-line);
  margin-bottom: 12px;

  strong {
    display: block;
    font-size: 14px;
    font-weight: 600;
  }

  small {
    display: block;
    margin-top: 2px;
    color: var(--apl-muted);
    font-size: 11px;
  }
}

.apl-brand-mark {
  display: grid;
  place-items: center;
  width: 34px;
  height: 34px;
  border-radius: 7px;
  background: var(--apl-accent);
  color: #111;
  font-size: 11px;
  font-weight: 800;
  letter-spacing: 0.5px;
}

.apl-nav {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.apl-nav-item {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-height: 40px;
  padding: 8px 10px;
  border: 0;
  border-radius: 4px;
  background: transparent;
  color: var(--apl-text);
  font: inherit;
  font-size: 13px;
  text-align: left;
  cursor: pointer;

  &:hover {
    background: #292d33;
  }

  &.active {
    color: var(--apl-accent);
    background: rgba(255, 138, 31, 0.09);
    box-shadow: inset 3px 0 0 var(--apl-accent);
  }
}

.apl-nav-icon {
  width: 18px;
  height: 18px;
  opacity: 0.9;
}

.apl-sidebar-bottom {
  margin-top: auto;
  padding-top: 12px;
  border-top: 1px solid var(--apl-line);
}

.apl-language {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 0 10px 10px;
  color: var(--apl-muted);
  font-size: 11px;
}

.apl-language-select {
  height: 28px;
  padding: 0 6px;
  border: 1px solid var(--apl-line);
  border-radius: 3px;
  background: #111316;
  color: var(--apl-text);
  font: inherit;
  font-size: 11px;
  outline: none;
}

.apl-version {
  padding: 0 10px;
  color: #6d737a;
  font-size: 10px;
  letter-spacing: 0.3px;
}

.apl-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.apl-topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 18px 24px 14px;

  h1 {
    margin: 0;
    font-size: 22px;
    font-weight: 600;
    letter-spacing: 0.2px;
  }

  p {
    margin: 4px 0 0;
    color: var(--apl-muted);
    font-size: 12px;
  }
}

.apl-mode {
  display: flex;
  padding: 3px;
  border: 1px solid var(--apl-line);
  border-radius: 7px;
  background: #111316;
}

.apl-mode-btn {
  padding: 7px 15px;
  border: 0;
  border-radius: 5px;
  background: transparent;
  color: var(--apl-muted);
  font: inherit;
  font-size: 12px;
  cursor: pointer;

  &.active {
    background: var(--apl-accent);
    color: #111;
    font-weight: 600;
  }
}

.apl-scroll {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 4px 24px 24px;
  scroll-behavior: smooth;
}

.apl-group {
  margin-bottom: 24px;
}

.apl-group-title {
  margin: 0 0 8px 4px;
  color: #fff;
  font-size: 14px;
  font-weight: 700;
  letter-spacing: 0.2px;
}

.apl-group-frame {
  overflow: hidden;
  border: 1px solid var(--apl-line);
  border-radius: 8px;
  background: var(--apl-panel);
}

.apl-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  min-height: 40px;
  padding: 6px 12px;
  background: var(--apl-panel-2);
  border-bottom: 1px solid var(--apl-line);

  &:last-child {
    border-bottom: 0;
  }
}

.apl-row-label {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;

  span {
    font-size: 13px;
  }

  small {
    color: var(--apl-muted);
    font-size: 11px;
    line-height: 1.3;
  }
}

.apl-toggle {
  position: relative;
  flex: 0 0 auto;
  width: 36px;
  height: 20px;
  padding: 0;
  border: 1px solid #3a3f46;
  border-radius: 999px;
  background: #2b2f35;
  cursor: pointer;
  transition: background 0.15s, border-color 0.15s;

  .apl-toggle-knob {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: #c4c8cd;
    transition: left 0.15s, background 0.15s;
  }

  &.on {
    border-color: var(--apl-accent);
    background: var(--apl-accent);

    .apl-toggle-knob {
      left: 18px;
      background: #fff;
    }
  }
}

.apl-cycle {
  display: flex;
  align-items: center;
  gap: 2px;
  min-width: 230px;
  height: 32px;
  border: 1px solid #343941;
  border-radius: 5px;
  background: #171a1e;
}

.apl-cycle-arrow {
  width: 30px;
  height: 100%;
  border: 0;
  background: transparent;
  color: #d9dde1;
  font-size: 21px;
  line-height: 1;
  cursor: pointer;

  &:hover {
    color: var(--apl-accent);
  }
}

.apl-cycle-value {
  flex: 1;
  text-align: center;
  font-size: 12px;
  color: #e7e9eb;
}

.apl-slider-cell {
  display: flex;
  align-items: center;
  gap: 8px;
  width: min(430px, 54%);
}

.apl-range {
  flex: 1;
  height: 3px;
  margin: 0;
  appearance: none;
  background: linear-gradient(to right, #b9bec4, #b9bec4);
  border-radius: 0;
  outline: none;
  cursor: pointer;

  &::-webkit-slider-thumb {
    appearance: none;
    width: 12px;
    height: 18px;
    border: 0;
    background: #fff;
    clip-path: polygon(22% 0, 100% 0, 78% 100%, 0 100%);
    box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.25);
  }

  &::-moz-range-thumb {
    width: 12px;
    height: 18px;
    border: 0;
    border-radius: 0;
    background: #fff;
    clip-path: polygon(22% 0, 100% 0, 78% 100%, 0 100%);
  }
}

.apl-number {
  width: 76px;
  height: 32px;
  padding: 0 8px;
  border: 1px solid #343941;
  border-radius: 4px;
  background: #171a1e;
  color: #e7e9eb;
  font: inherit;
  font-size: 12px;
  text-align: right;
  outline: none;

  &:focus {
    border-color: var(--apl-accent);
  }
}

.apl-about {
  padding: 14px;

  p {
    margin: 0 0 12px;
    color: var(--apl-muted);
    font-size: 12px;
    line-height: 1.45;
  }
}

.apl-preview {
  display: block;
  width: 100%;
  max-height: 280px;
  object-fit: contain;
  background: #fff;
  border: 1px solid #fff;
  border-radius: 5px;
}

.apl-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 11px 24px;
  border-top: 1px solid var(--apl-line);
  background: #16181b;
}

.apl-message {
  min-height: 16px;
  color: var(--apl-muted);
  font-size: 11px;
}

.apl-error {
  color: #ff7777;
}

.apl-footer-actions {
  display: flex;
  gap: 8px;
}

.apl-btn {
  min-width: 96px;
  height: 32px;
  padding: 0 16px;
  border: 1px solid #353b43;
  border-radius: 5px;
  font: inherit;
  font-size: 12px;
  cursor: pointer;

  &.secondary {
    background: #23272d;
    color: #d7dbdf;

    &:hover {
      background: #2b3037;
    }
  }

  &.primary {
    border-color: var(--apl-accent);
    background: var(--apl-accent);
    color: #111;
    font-weight: 600;

    &:hover {
      filter: brightness(1.08);
    }
  }
}

.apl-empty {
  display: grid;
  place-items: center;
  min-height: 220px;
  color: var(--apl-muted);
  font-size: 13px;
}
</style>
