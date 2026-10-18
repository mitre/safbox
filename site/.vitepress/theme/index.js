// The default VitePress theme with the MITRE SAF brand colours, plus the
// start page's live service status.
import DefaultTheme from 'vitepress/theme';
import ServiceStatus from './ServiceStatus.vue';
import './custom.css';

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('ServiceStatus', ServiceStatus);
  },
};
