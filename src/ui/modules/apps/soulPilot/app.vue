<template>
  <div class="apl-shell">
    <aside class="apl-sidebar">
      <div class="apl-brand">
        <span class="apl-brand-mark">{{ t("apl.ui.brandMark") }}</span>
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
        <div ref="langRoot" class="apl-language">
          <button class="apl-lang-current" @click.stop="langOpen = !langOpen">
            <span>{{ currentLanguage.label }}</span>
            <span class="apl-lang-arrow">{{ langOpen ? "▴" : "▾" }}</span>
          </button>
          <div v-if="langOpen" class="apl-lang-menu">
            <button
              v-for="item in languages"
              :key="item.id"
              class="apl-lang-btn"
              :class="{ active: lang === item.id }"
              @click.stop="changeLanguage(item.id)"
            >
              {{ item.label }}
            </button>
          </div>
        </div>
        <div class="apl-version">{{ t("apl.ui.version") }}</div>
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
          <GeneralSettings
            :t="t"
            :module-state="moduleState"
            @toggle="toggleModule"
          />
          <SteeringSettings
            :t="t"
            :mode="mode"
            :profile-label="profileLabel"
            :fields="expert.steering"
            :get-val="getVal"
            :set-val="setVal"
            @cycle-profile="cycleProfile"
          />
          <MusicSettings
            :t="t"
            :mode="mode"
            :module-state="moduleState"
            :fields="expert.music"
            :get-val="getVal"
            :set-val="setVal"
            @toggle="toggleModule"
          />
          <DebugSettings
            :t="t"
            :debug-enabled="debugEnabled"
            @toggle="toggleDebug"
          />
          <AboutPanel :t="t" />
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
import { computed, onBeforeUnmount, onMounted, reactive, ref } from "vue"
import { BngIcon } from "@/common/components/base"
import { useBridge } from "@/bridge"
import GeneralSettings from "./components/GeneralSettings.vue"
import SteeringSettings from "./components/SteeringSettings.vue"
import MusicSettings from "./components/MusicSettings.vue"
import DebugSettings from "./components/DebugSettings.vue"
import AboutPanel from "./components/AboutPanel.vue"
import { MESSAGES } from "./messages.js"
import "./styles.scss"

const { api } = useBridge()



const scrollArea = ref(null)
const lang = ref("en")
const languages = [
  { id: "ru", label: "RU" },
  { id: "en", label: "EN" },
  { id: "uk", label: "UK" },
  { id: "by", label: "BY" },
]

const langOpen = ref(false)
const langRoot = ref(null)
const currentLanguage = computed(
  () => languages.find(item => item.id === lang.value) || languages[1],
)

function closeLangMenu(event) {
  if (langRoot.value && !langRoot.value.contains(event.target)) {
    langOpen.value = false
  }
}

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
}

function applyStatus(status) {
  if (!status) return
  moduleState.master = status.master === true || status.master === 1 || status.master === "on"
  moduleState.lights = status.lights === true
  moduleState.music = status.music === true
  debugEnabled.value = status.debug === true
  if (status.language) lang.value = normalizeLang(status.language)
}

function changeLanguage(nextLang) {
  langOpen.value = false
  if (!nextLang || nextLang === lang.value) return
  const previous = lang.value
  lang.value = nextLang
  error.value = ""
  messageKey.value = ""
  api.engineLua(
    `extensions.soulPilot_uiConfig.setLanguage(${JSON.stringify(nextLang)})`,
    result => {
      if (!result || result.ok === false) {
        lang.value = previous
        error.value = (result && result.error) || t("apl.errors.saveLanguage")
        return
      }
      messageKey.value = "apl.ui.saved"
    },
  )
}

function refresh() {
  loading.value = true
  error.value = ""
  api.engineLua("extensions.soulPilot_uiConfig.getConfig()", data => {
    loading.value = false
    if (!data || !data.values) {
      error.value = t("apl.errors.noConfig")
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
    `extensions.soulPilot_uiConfig.setModule(${JSON.stringify(id)}, ${next ? "true" : "false"})`,
    saved => {
      if (saved !== true) {
        moduleState[id] = !next
        error.value = t("apl.errors.setting")
        return
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
    `extensions.soulPilot_uiConfig.setDebug(${next ? "true" : "false"})`,
    result => {
      if (!result || result.ok === false) {
        debugEnabled.value = !next
        error.value = (result && result.error) || t("apl.errors.debug")
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
    `extensions.soulPilot_uiConfig.setConfig(${api.serializeToLua({ files })})`,
    result => {
      if (!result || result.ok === false) {
        error.value = (result && result.error) || t("apl.errors.save")
        return
      }
      state.dirty = {}
      messageKey.value = result.requiresRespawn ? "apl.ui.requiresRespawn" : "apl.ui.saved"
    },
  )
}

onMounted(() => {
  document.addEventListener("click", closeLangMenu)
  refresh()
})

onBeforeUnmount(() => {
  document.removeEventListener("click", closeLangMenu)
})
</script>
