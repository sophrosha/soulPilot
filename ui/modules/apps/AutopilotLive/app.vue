<template>
  <div class="apl-app bngApp">
    <header class="apl-header">
      <div class="brand">
        <div class="brand-mark">APL</div>
        <div>
          <h1>{{ $t("apl.ui.title") }}</h1>
          <p>{{ $t("apl.ui.subtitle") }}</p>
        </div>
      </div>
      <div class="mode-switch">
        <button
          class="mode-btn"
          :class="{ active: state.mode === 'normal' }"
          @click="state.mode = 'normal'"
        >
          {{ $t("apl.ui.normal") }}
        </button>
        <button
          class="mode-btn"
          :class="{ active: state.mode === 'expert' }"
          @click="state.mode = 'expert'"
        >
          {{ $t("apl.ui.expert") }}
        </button>
      </div>
    </header>

    <div v-if="state.loading" class="apl-empty">
      {{ $t("apl.ui.loading") }}
    </div>

    <template v-else>
      <nav class="apl-tabs">
        <button
          v-for="tab in tabs"
          :key="tab.id"
          class="tab-btn"
          :class="{ active: state.tab === tab.id }"
          @click="state.tab = tab.id"
        >
          {{ $t(tab.label) }}
        </button>
      </nav>

      <main class="apl-body">
        <section v-if="state.tab === 'overview'" class="apl-grid">
          <article v-for="card in cards" :key="card.id" class="apl-card">
            <div class="card-head">
              <div>
                <h3>{{ $t(card.title) }}</h3>
                <span class="card-badge">{{ card.badge }}</span>
              </div>
              <BngSwitch
                :model-value="moduleState[card.id]"
                @update:model-value="v => toggleModule(card.id, v)"
              />
            </div>
            <p>{{ $t(card.desc) }}</p>
          </article>

          <article class="apl-card apl-status">
            <div class="card-head">
              <h3>{{ $t("apl.ui.state") }}</h3>
            </div>
            <div class="status-line">
              <span>{{ $t("apl.modules.master") }}</span>
              <b>{{ state.status.master || "off" }}</b>
            </div>
            <div class="status-line">
              <span>{{ $t("apl.modules.music") }}</span>
              <b>{{ moduleState.music ? "ON" : "OFF" }}</b>
            </div>
            <div class="status-line">
              <span>{{ $t("apl.modules.lights") }}</span>
              <b>{{ moduleState.lights ? "ON" : "OFF" }}</b>
            </div>
            <div class="status-line">
              <span>{{ $t("apl.modules.parking") }}</span>
              <b>{{ moduleState.parking ? "ON" : "OFF" }}</b>
            </div>
          </article>
        </section>

        <section v-else-if="state.tab === 'music'" class="apl-panel">
          <div v-if="state.mode === 'normal'" class="simple-row">
            <div>
              <h3>{{ $t("apl.modules.music") }}</h3>
              <p>{{ $t("apl.modules.music.desc") }}</p>
            </div>
            <BngSwitch
              :model-value="moduleState.music"
              @update:model-value="v => toggleModule('music', v)"
            />
          </div>
          <template v-else>
            <div v-for="f in expert.music" :key="f.path" class="slider-row">
              <span class="slider-label">{{ $t(f.label) }}</span>
              <BngSlider
                :model-value="getVal(f.file, f.path)"
                :min="f.min"
                :max="f.max"
                :step="f.step"
                @update:model-value="v => setVal(f.file, f.path, v)"
              />
              <span class="slider-value">{{ formatVal(getVal(f.file, f.path)) }}</span>
            </div>
          </template>
        </section>

        <section v-else-if="state.tab === 'wheel'" class="apl-panel">
          <div v-if="state.mode === 'normal'" class="simple-row">
            <div>
              <h3>{{ $t("apl.modules.wheel") }}</h3>
              <p>{{ $t("apl.modules.wheel.desc") }}</p>
            </div>
            <BngSwitch
              :model-value="moduleState.wheel"
              @update:model-value="v => toggleModule('wheel', v)"
            />
          </div>
          <template v-else>
            <div v-for="f in expert.wheel" :key="f.path" class="slider-row">
              <span class="slider-label">{{ $t(f.label) }}</span>
              <BngSlider
                :model-value="getVal(f.file, f.path)"
                :min="f.min"
                :max="f.max"
                :step="f.step"
                @update:model-value="v => setVal(f.file, f.path, v)"
              />
              <span class="slider-value">{{ formatVal(getVal(f.file, f.path)) }}</span>
            </div>
          </template>
        </section>

        <section v-else-if="state.tab === 'parking'" class="apl-panel">
          <div v-if="state.mode === 'normal'" class="simple-row">
            <div>
              <h3>{{ $t("apl.modules.parking") }}</h3>
              <p>{{ $t("apl.modules.parking.desc") }}</p>
            </div>
            <BngSwitch
              :model-value="moduleState.parking"
              @update:model-value="v => toggleModule('parking', v)"
            />
          </div>
          <template v-else>
            <div v-for="f in expert.parking" :key="f.path" class="slider-row">
              <span class="slider-label">{{ $t(f.label) }}</span>
              <BngSlider
                :model-value="getVal(f.file, f.path)"
                :min="f.min"
                :max="f.max"
                :step="f.step"
                @update:model-value="v => setVal(f.file, f.path, v)"
              />
              <span class="slider-value">{{ formatVal(getVal(f.file, f.path)) }}</span>
            </div>
          </template>
        </section>

        <section v-else class="apl-panel about">
          <h3>{{ $t("apl.ui.title") }}</h3>
          <p>{{ $t("apl.ui.aboutText") }}</p>
          <p class="muted">{{ $t("apl.ui.expertHint") }}</p>
        </section>
      </main>

      <footer class="apl-footer">
        <div class="footer-message">
          <span v-if="state.error" class="error">{{ state.error }}</span>
          <span v-else-if="state.messageKey">{{ $t(state.messageKey) }}</span>
        </div>
        <div class="footer-actions">
          <BngButton accent="secondary" @click="refresh">{{ $t("apl.ui.refresh") }}</BngButton>
          <BngButton v-if="state.mode === 'expert'" accent="main" @click="save">
            {{ $t("apl.ui.save") }}
          </BngButton>
        </div>
      </footer>
    </template>
  </div>
</template>

<script setup>
import { onMounted, reactive } from "vue"
import { BngButton, BngSlider, BngSwitch } from "@/common/components/base"
import { useBridge } from "@/bridge"

const { api } = useBridge()

const state = reactive({
  loading: true,
  mode: "normal",
  tab: "overview",
  values: {},
  status: {},
  dirty: {},
  messageKey: "",
  error: "",
})

const moduleState = reactive({
  master: false,
  lights: false,
  music: false,
  parking: false,
  wheel: false,
  popup: false,
})

const tabs = [
  { id: "overview", label: "apl.ui.overview" },
  { id: "music", label: "apl.ui.music" },
  { id: "wheel", label: "apl.ui.wheel" },
  { id: "parking", label: "apl.ui.parking" },
  { id: "about", label: "apl.ui.about" },
]

const cards = [
  { id: "master", title: "apl.modules.master", desc: "apl.modules.master.desc", badge: "AI" },
  { id: "lights", title: "apl.modules.lights", desc: "apl.modules.lights.desc", badge: "AUTO" },
  { id: "music", title: "apl.modules.music", desc: "apl.modules.music.desc", badge: "BASS" },
  { id: "parking", title: "apl.modules.parking", desc: "apl.modules.parking.desc", badge: "P1" },
]

const expert = {
  music: [
    { file: "music", path: "sway_amp", label: "apl.fields.sway_amp", min: 0, max: 0.05, step: 0.001 },
    { file: "music", path: "vibration_amp", label: "apl.fields.vibration_amp", min: 0, max: 0.01, step: 0.0005 },
    { file: "music", path: "beat_amp", label: "apl.fields.beat_amp", min: 0, max: 0.05, step: 0.001 },
    { file: "music", path: "beat_decay_s", label: "apl.fields.beat_decay_s", min: 0.02, max: 1, step: 0.01 },
    { file: "music", path: "vibration_hz", label: "apl.fields.vibration_hz", min: 1, max: 15, step: 0.5 },
  ],
  wheel: [
    { file: "wheel", path: "rate_limit.steer_rise", label: "apl.fields.steer_rise", min: 1, max: 20, step: 0.1 },
    { file: "wheel", path: "rate_limit.steer_fall", label: "apl.fields.steer_fall", min: 1, max: 20, step: 0.1 },
    { file: "wheel", path: "ema_tau.steer", label: "apl.fields.ema_tau", min: 0.01, max: 0.5, step: 0.01 },
    { file: "wheel", path: "lerp_tau.steer", label: "apl.fields.lerp_tau", min: 0.01, max: 0.5, step: 0.01 },
  ],
  parking: [
    { file: "parking", path: "route_speed_mps", label: "apl.fields.route_speed", min: 1, max: 20, step: 0.5 },
    { file: "parking", path: "arrival_radius_m", label: "apl.fields.arrival_radius", min: 3, max: 50, step: 1 },
    { file: "parking", path: "stop_speed_mps", label: "apl.fields.stop_speed", min: 0.1, max: 2, step: 0.05 },
  ],
}

function applyStatus(status) {
  if (!status) return
  moduleState.master = status.master === "on" || status.master === "waiting_warmup"
  moduleState.lights = status.lights === true
  moduleState.music = status.music === true
  moduleState.parking = status.parking === true
  moduleState.wheel = status.wheel === true
  moduleState.popup = status.popup === true
}

function refresh() {
  state.loading = true
  state.error = ""
  api.engineLua("extensions.autopilotLive_uiConfig.getConfig()", data => {
    state.loading = false
    if (!data || !data.values) {
      state.error = "AutopilotLive UI config not available"
      return
    }
    state.values = data.values
    state.status = data.state || {}
    state.dirty = {}
    state.messageKey = ""
    applyStatus(state.status)
  })
}

function toggleModule(id, value) {
  moduleState[id] = value
  state.error = ""
  state.messageKey = ""
  api.engineLua(
    `extensions.autopilotLive_uiConfig.setModule(${JSON.stringify(id)}, ${value ? "true" : "false"})`,
    result => {
      if (!result || result.ok === false) {
        moduleState[id] = !value
        state.error = (result && result.error) || "Unable to change module"
        return
      }
      if (result.state) {
        state.status = result.state
        applyStatus(result.state)
      }
      state.messageKey = "apl.ui.saved"
    },
  )
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
  state.messageKey = ""
}

function formatVal(value) {
  const number = Number(value)
  if (!Number.isFinite(number)) return "0"
  return number.toFixed(3).replace(/0+$/, "").replace(/\.$/, "")
}

function save() {
  const files = {}
  for (const file of Object.keys(state.dirty)) {
    if (state.dirty[file]) files[file] = state.values[file]
  }
  if (Object.keys(files).length === 0) {
    state.messageKey = "apl.ui.noChanges"
    return
  }
  state.error = ""
  api.engineLua(
    `extensions.autopilotLive_uiConfig.setConfig(${api.serializeToLua({ files })})`,
    result => {
      if (!result || result.ok === false) {
        state.error = (result && result.error) || "Save failed"
        return
      }
      state.dirty = {}
      state.messageKey = result.requiresRespawn ? "apl.ui.requiresRespawn" : "apl.ui.saved"
    },
  )
}

onMounted(refresh)
</script>

<style scoped lang="scss">
.apl-app {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  color: #eee;
  background:
    radial-gradient(circle at 20% 0%, rgba(255, 120, 30, 0.14), transparent 45%),
    linear-gradient(160deg, rgba(18, 20, 24, 0.97), rgba(9, 11, 14, 0.98));
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 10px;
  font-family: var(--fnt-defs, sans-serif);

  .apl-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 18px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(0, 0, 0, 0.25);
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 12px;

    h1 {
      margin: 0;
      font-size: 22px;
      letter-spacing: 0.4px;
    }

    p {
      margin: 2px 0 0;
      color: #9aa0a6;
      font-size: 12px;
    }
  }

  .brand-mark {
    display: grid;
    place-items: center;
    width: 42px;
    height: 42px;
    border-radius: 9px;
    background: var(--bng-orange, #ff7a1a);
    color: #111;
    font-weight: 800;
    font-size: 13px;
    letter-spacing: 0.5px;
  }

  .mode-switch {
    display: flex;
    gap: 4px;
    padding: 3px;
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.06);
  }

  .mode-btn,
  .tab-btn {
    border: 0;
    background: transparent;
    color: #b8bdc3;
    padding: 8px 14px;
    border-radius: 6px;
    cursor: pointer;
    font: inherit;
    font-size: 13px;
  }

  .mode-btn.active,
  .tab-btn.active {
    background: rgba(255, 122, 26, 0.16);
    color: #ff9a4d;
  }

  .apl-tabs {
    display: flex;
    gap: 4px;
    padding: 8px 16px 0;
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  }

  .tab-btn {
    padding: 10px 14px;
    border-radius: 7px 7px 0 0;
  }

  .apl-body {
    flex: 1;
    overflow: auto;
    padding: 16px;
  }

  .apl-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
    gap: 12px;
  }

  .apl-card {
    min-height: 112px;
    padding: 14px;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 9px;
    background: rgba(255, 255, 255, 0.035);

    .card-head {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 10px;
    }

    h3 {
      margin: 0;
      font-size: 16px;
    }

    p {
      margin: 8px 0 0;
      color: #9aa0a6;
      font-size: 12px;
      line-height: 1.4;
    }
  }

  .card-badge {
    color: #ff9a4d;
    font-size: 10px;
    letter-spacing: 1px;
    opacity: 0.8;
  }

  .apl-status {
    background: rgba(255, 122, 26, 0.055);
  }

  .status-line {
    display: flex;
    justify-content: space-between;
    margin-top: 8px;
    color: #aeb4ba;
    font-size: 12px;

    b {
      color: #f2f2f2;
    }
  }

  .apl-panel {
    max-width: 720px;
  }

  .simple-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    padding: 16px;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 9px;
    background: rgba(255, 255, 255, 0.035);

    h3 {
      margin: 0;
    }

    p {
      margin: 6px 0 0;
      color: #9aa0a6;
      font-size: 12px;
    }
  }

  .slider-row {
    display: grid;
    grid-template-columns: 190px 1fr 64px;
    align-items: center;
    gap: 14px;
    padding: 12px 8px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
  }

  .slider-label {
    color: #c9ced4;
    font-size: 13px;
  }

  .slider-value {
    color: #ff9a4d;
    font-variant-numeric: tabular-nums;
    text-align: right;
  }

  .apl-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 16px;
    border-top: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(0, 0, 0, 0.22);
  }

  .footer-message {
    color: #9aa0a6;
    font-size: 12px;
    min-height: 18px;
  }

  .error {
    color: #ff7d7d;
  }

  .footer-actions {
    display: flex;
    gap: 8px;
  }

  .apl-empty {
    flex: 1;
    display: grid;
    place-items: center;
    color: #9aa0a6;
  }

  .muted {
    color: #9aa0a6;
  }

  .about {
    h3 {
      margin-top: 0;
    }
  }
}
</style>
