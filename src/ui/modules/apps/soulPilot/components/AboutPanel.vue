<template>
  <section id="about" class="apl-group">
    <h2 class="apl-group-title">{{ t("apl.ui.about") }}</h2>
    <div class="apl-group-frame apl-about">
      <div class="about-hero">
        <h3>{{ t("apl.about.product") }}</h3>
        <span class="about-version">{{ t("apl.about.version") }}</span>
        <p>{{ t("apl.about.description") }}</p>
      </div>

      <div class="about-block">
        <h4>{{ t("apl.about.sources") }}</h4>
        <p>
          {{ t("apl.about.purring") }}
          <a href="https://zvukogram.com/zvuk/44356/" target="_blank" rel="noopener">
            zvukogram.com/zvuk/44356/
          </a>
        </p>
      </div>

      <div class="about-block">
        <h4>{{ t("apl.about.info") }}</h4>
        <p>{{ t("apl.about.author") }}</p>
      </div>

      <div class="about-block">
        <h4>{{ t("apl.about.links") }}</h4>
        <div class="about-links">
          <a class="about-link" href="https://github.com/sophrosha" target="_blank" rel="noopener">
            <img
              class="about-icon"
              src="/ui/modules/apps/soulPilot/github.svg"
              :alt="t('apl.about.github')"
            />
            <span class="about-link-text">
              {{ t("apl.about.github") }}
              <small>github.com/sophrosha</small>
            </span>
          </a>
          <a class="about-link" href="https://sophron.ru" target="_blank" rel="noopener">
            <img
              class="about-icon about-icon-site"
              src="/ui/modules/apps/soulPilot/bio.svg"
              :alt="t('apl.about.website')"
            />
            <span class="about-link-text">
              {{ t("apl.about.website") }}
              <small>sophron.ru</small>
            </span>
          </a>
        </div>
      </div>
    </div>
  </section>
</template>

<script setup>
defineProps({
  t: { type: Function, required: true },
})
</script>
