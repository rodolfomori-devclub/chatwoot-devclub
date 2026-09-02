import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { routeIsAccessibleFor } from 'dashboard/helper/routeHelpers';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
// The page components pull in the settings layout, which reaches the router
// module and back into this very file. Only the route table is under test, so
// they are stubbed to keep the import graph acyclic.
vi.mock('../pages/TriageFlowIndexPage.vue', () => ({ default: {} }));
vi.mock('../pages/TriageFlowCreatePage.vue', () => ({ default: {} }));
vi.mock('../pages/TriageFlowEditPage.vue', () => ({ default: {} }));
vi.mock('../../SettingsWrapper.vue', () => ({ default: {} }));

import triageFlowRoutes from '../triageFlows.routes';

const pages = triageFlowRoutes.routes[0].children.filter(child => child.name);

describe('triage flow routes', () => {
  it('exposes the three pages the sidebar and the pages link to', () => {
    expect(pages.map(page => page.name)).toEqual([
      'triage_flows_index',
      'triage_flows_new',
      'triage_flows_edit',
    ]);
  });

  it('carries the same flag name the backend gates the API on', () => {
    // config/features.yml is what Account#feature_enabled? reads, and the
    // controller answers 403 on every action when it is off. A typo on either
    // side would leave the menu entry visible and every request refused.
    const features = readFileSync(
      resolve(process.cwd(), 'config/features.yml'),
      'utf8'
    );

    expect(FEATURE_FLAGS.TRIAGE_FLOWS).toBe('triage_flows');
    expect(features).toContain('- name: triage_flows');
  });

  it('tags every page with the feature flag and the admin permission', () => {
    pages.forEach(page => {
      expect(page.meta).toEqual({
        featureFlag: FEATURE_FLAGS.TRIAGE_FLOWS,
        permissions: ['administrator'],
      });
    });
  });

  it('refuses every page to an agent', () => {
    pages.forEach(page => {
      expect(routeIsAccessibleFor(page, ['agent'])).toBe(false);
      expect(routeIsAccessibleFor(page, ['administrator'])).toBe(true);
    });
  });

  // Chatwoot's router guard only reads meta.permissions; meta.featureFlag is
  // consumed by components-next/sidebar/provider.js, which hides the entry
  // when the account does not have the feature. Triage Flows follows the same
  // contract as SLA and the rest of settings, so a direct hit on the URL with
  // the flag off still renders the page and every request it makes comes back
  // 403. Pinned here so the day the platform starts enforcing the flag in the
  // router, this is the spec that says these routes were relying on it.
  it('is gated by the sidebar, not by the router', () => {
    const [index] = pages;

    expect(routeIsAccessibleFor(index, ['administrator'])).toBe(true);
    expect(index.meta.featureFlag).toBe('triage_flows');
  });
});
