import './app.css';
import { mount } from 'svelte';

import { dashboardClient } from '$shared/dashboard-client';

import App from './App.svelte';

const app = mount(App, { target: document.getElementById('app')! });

void dashboardClient.initialize();

export default app;
