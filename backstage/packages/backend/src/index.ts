import { createBackend } from '@backstage/backend-defaults';
import { createBackendModule } from '@backstage/backend-plugin-api';
import { githubAuthenticator } from '@backstage/plugin-auth-backend-module-github-provider';
import {
  authProvidersExtensionPoint,
  createOAuthProviderFactory,
} from '@backstage/plugin-auth-node';

const githubSignInModule = createBackendModule({
  pluginId: 'auth',
  moduleId: 'github-sign-in',
  register(reg) {
    reg.registerInit({
      deps: { providers: authProvidersExtensionPoint },
      async init({ providers }) {
        providers.registerProvider({
          providerId: 'github',
          factory: createOAuthProviderFactory({
            authenticator: githubAuthenticator,
            async signInResolver({ result }, ctx) {
              const userId = result.fullProfile.username;
              if (!userId) {
                throw new Error('GitHub username missing from profile');
              }
              return ctx.issueToken({
                claims: {
                  sub: `user:default/${userId}`,
                  ent: [`user:default/${userId}`],
                },
              });
            },
          }),
        });
      },
    });
  },
});

const backend = createBackend();

backend.add(import('@backstage/plugin-app-backend'));
backend.add(import('@backstage/plugin-proxy-backend'));

// catalog
backend.add(import('@backstage/plugin-catalog-backend'));
backend.add(
  import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'),
);

// scaffolder
backend.add(import('@backstage/plugin-scaffolder-backend'));
backend.add(import('@backstage/plugin-scaffolder-backend-module-github'));

// auth (GitHub provider with custom sign-in resolver)
backend.add(import('@backstage/plugin-auth-backend'));
backend.add(githubSignInModule);

// kubernetes
backend.add(import('@backstage/plugin-kubernetes-backend'));

// security — Kyverno Policy Reporter
backend.add(import('@kyverno/backstage-plugin-policy-reporter-backend'));

// TeraSky plugins — Kubernetes & Crossplane
backend.add(import('@terasky/backstage-plugin-kubernetes-ingestor'));
backend.add(import('@terasky/backstage-plugin-crossplane-resources-backend'));
backend.add(import('@terasky/backstage-plugin-kubernetes-resources-permissions-backend'));
backend.add(import('@terasky/backstage-plugin-scaffolder-backend-module-terasky-utils'));

// permissions (allow-all for lab)
backend.add(import('@backstage/plugin-permission-backend'));
backend.add(
  import('@backstage/plugin-permission-backend-module-allow-all-policy'),
);

backend.start().catch(error => {
  console.error('Backend failed to start:', error);
  process.exit(1);
});
