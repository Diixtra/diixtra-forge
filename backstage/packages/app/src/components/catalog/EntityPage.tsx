import { Grid } from '@mui/material';
import {
  EntityAboutCard,
  EntityLayout,
  EntityLinksCard,
  EntitySwitch,
  isKind,
} from '@backstage/plugin-catalog';
import {
  EntityKubernetesContent,
  isKubernetesAvailable,
} from '@backstage/plugin-kubernetes';
import {
  CrossplaneOverviewCardSelector,
  CrossplaneResourceGraphSelector,
  CrossplaneResourcesTableSelector,
  isCrossplaneAvailable,
} from '@terasky/backstage-plugin-crossplane-resources-frontend';
import {
  KubernetesResourcesPage,
  isKubernetesResourcesAvailable,
} from '@terasky/backstage-plugin-kubernetes-resources-frontend';
import { EntityScaffolderContent } from '@terasky/backstage-plugin-entity-scaffolder-content';

// ---------------------------------------------------------------------------
// Shared overview content (used by most entity types)
// ---------------------------------------------------------------------------
const overviewContent = (
  <Grid container spacing={3}>
    <Grid item md={6}>
      <EntityAboutCard variant="gridItem" />
    </Grid>
    <Grid item md={6}>
      <EntityLinksCard />
    </Grid>
  </Grid>
);

// ---------------------------------------------------------------------------
// Service / Component entity page
// ---------------------------------------------------------------------------
const serviceEntityPage = (
  <EntityLayout>
    <EntityLayout.Route path="/" title="Overview">
      {overviewContent}
    </EntityLayout.Route>

    <EntityLayout.Route
      path="/kubernetes"
      title="Kubernetes"
      if={isKubernetesAvailable}
    >
      <EntityKubernetesContent />
    </EntityLayout.Route>

    <EntityLayout.Route
      path="/kubernetes-resources"
      title="K8s Resources"
      if={isKubernetesResourcesAvailable}
    >
      <KubernetesResourcesPage />
    </EntityLayout.Route>

    <EntityLayout.Route
      path="/crossplane"
      title="Crossplane"
      if={isCrossplaneAvailable}
    >
      <Grid container spacing={3}>
        <Grid item md={12}>
          <CrossplaneOverviewCardSelector />
        </Grid>
        <Grid item md={12}>
          <CrossplaneResourceGraphSelector />
        </Grid>
        <Grid item md={12}>
          <CrossplaneResourcesTableSelector />
        </Grid>
      </Grid>
    </EntityLayout.Route>
  </EntityLayout>
);

// ---------------------------------------------------------------------------
// Resource entity page (e.g. kubernetes-cluster, database, s3-bucket)
// ---------------------------------------------------------------------------
const resourceEntityPage = (
  <EntityLayout>
    <EntityLayout.Route path="/" title="Overview">
      {overviewContent}
    </EntityLayout.Route>

    <EntityLayout.Route
      path="/kubernetes"
      title="Kubernetes"
      if={isKubernetesAvailable}
    >
      <EntityKubernetesContent />
    </EntityLayout.Route>

    <EntityLayout.Route
      path="/kubernetes-resources"
      title="K8s Resources"
      if={isKubernetesResourcesAvailable}
    >
      <KubernetesResourcesPage />
    </EntityLayout.Route>

    <EntityLayout.Route
      path="/crossplane"
      title="Crossplane"
      if={isCrossplaneAvailable}
    >
      <Grid container spacing={3}>
        <Grid item md={12}>
          <CrossplaneOverviewCardSelector />
        </Grid>
        <Grid item md={12}>
          <CrossplaneResourceGraphSelector />
        </Grid>
        <Grid item md={12}>
          <CrossplaneResourcesTableSelector />
        </Grid>
      </Grid>
    </EntityLayout.Route>

    <EntityLayout.Route path="/scaffolder" title="Actions">
      <EntityScaffolderContent
        templateGroupFilters={[
          {
            title: 'Actions for this resource',
            filter: (_entity, template) =>
              template.metadata.tags?.includes('resource') ?? false,
          },
        ]}
        buildInitialState={(entity, _template) => ({
          resourceRef: `${entity.kind}:${entity.metadata.namespace ?? 'default'}/${entity.metadata.name}`,
        })}
      />
    </EntityLayout.Route>
  </EntityLayout>
);

// ---------------------------------------------------------------------------
// Default entity page (fallback for all other entity kinds)
// ---------------------------------------------------------------------------
const defaultEntityPage = (
  <EntityLayout>
    <EntityLayout.Route path="/" title="Overview">
      {overviewContent}
    </EntityLayout.Route>
  </EntityLayout>
);

// ---------------------------------------------------------------------------
// EntityPage — switches layout based on entity kind/type
// ---------------------------------------------------------------------------
export const entityPage = (
  <EntitySwitch>
    <EntitySwitch.Case if={isKind('component')} children={serviceEntityPage} />
    <EntitySwitch.Case if={isKind('resource')} children={resourceEntityPage} />
    <EntitySwitch.Case>{defaultEntityPage}</EntitySwitch.Case>
  </EntitySwitch>
);
