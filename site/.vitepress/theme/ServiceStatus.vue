<script setup>
// Live service status on the start page. The box writes /status.json every
// minute; off the box (or before the first write) there is none, and the
// component says so.
import { onMounted, ref } from 'vue';

const status = ref(null);
const failed = ref(false);

onMounted(async () => {
  try {
    const response = await fetch('/status.json', { cache: 'no-store' });
    if (!response.ok) throw new Error(String(response.status));
    status.value = await response.json();
  } catch {
    failed.value = true;
  }
});
</script>

<template>
  <div class="service-status">
    <p v-if="failed">Live status is shown when this page is served by a SAFBox.</p>
    <p v-else-if="!status">Checking the services…</p>
    <template v-else>
      <table>
        <thead>
          <tr><th>Service</th><th>State</th></tr>
        </thead>
        <tbody>
          <tr v-for="service in status.services" :key="service.name">
            <td>
              <a v-if="service.url" :href="service.url">{{ service.name }}</a>
              <span v-else>{{ service.name }}</span>
            </td>
            <td :class="service.state">{{ service.state }}</td>
          </tr>
        </tbody>
      </table>
      <p class="updated">Checked {{ status.updated }}</p>
    </template>
  </div>
</template>

<style scoped>
.up { color: var(--vp-c-green-1); font-weight: 600; }
.down { color: var(--vp-c-red-1); font-weight: 600; }
.updated { font-size: 0.85em; color: var(--vp-c-text-2); }
</style>
