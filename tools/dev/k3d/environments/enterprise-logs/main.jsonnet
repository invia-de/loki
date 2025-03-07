local k = import 'github.com/grafana/jsonnet-libs/ksonnet-util/kausal.libsonnet';
local tanka = import 'github.com/grafana/jsonnet-libs/tanka-util/main.libsonnet';

local provisioner = import 'provisioner/provisioner.libsonnet';

local grafana = import 'grafana/grafana.libsonnet';
local envVar = if std.objectHasAll(k.core.v1, 'envVar') then k.core.v1.envVar else k.core.v1.container.envType;
local helm = tanka.helm.new(std.thisFile);

local spec = (import './spec.json').spec;

provisioner {
  local prometheusServerName = self.prometheus.service_prometheus_kube_prometheus_prometheus.metadata.name,
  local prometheusUrl = 'http://%s:9090' % prometheusServerName,

  local lokiGatewayHost = self.loki.service_enterprise_logs_gateway.metadata.name,
  local lokiGatewayUrl = 'http://%s' % lokiGatewayHost,

  local licenseClusterName = 'enterprise-logs-test-fixture',
  local provisionerSecret = 'gel-provisioning-tokens',
  local adminTokenSecret = 'gel-admin-token',

  local tenant = 'team-l',

  _images+:: {
    provisioner: '%s/enterprise-logs-provisioner' % std.extVar('registry'),
  },

  _config+:: {
    clusterName: licenseClusterName,
    namespace: spec.namespace,
    adminTokenSecret: adminTokenSecret,
    adminApiUrl: lokiGatewayUrl,
    provisioner+: {
      initCommand: [
        '/usr/bin/enterprise-logs-provisioner',

        '-bootstrap-path=/bootstrap',
        '-cluster-name=' + licenseClusterName,
        '-gel-url=' + lokiGatewayUrl,

        '-instance=%s' % tenant,

        '-access-policy=promtail-l:team-l:logs:write',
        '-access-policy=grafana-l:team-l:logs:read',

        '-token=promtail-l',
        '-token=grafana-l',
      ],
      containerCommand: [
        'bash',
        '-c',
        'kubectl create secret generic '
        + provisionerSecret
        + ' --from-literal=token-promtail-l="$(cat /bootstrap/token-promtail-l)"'
        + ' --from-literal=token-grafana-l="$(cat /bootstrap/token-grafana-l)" ',
      ],
    },
  },

  loki: helm.template($._config.clusterName, '../../../../../production/helm/loki', {
    namespace: $._config.namespace,
    values: {
      loki+: {},
      enterprise+: {
        enabled: true,
        license: {
          contents: importstr '../../secrets/gel.jwt',
        },
        tokengen: {
          enable: true,
          adminTokenSecret: adminTokenSecret,
        },
      },
      minio+: {
        enabled: true,
      },
    },
  }),

  prometheus: helm.template('prometheus', '../../charts/kube-prometheus-stack', {
    namespace: $._config.namespace,
    values+: {
      grafana+: {
        enabled: false,
      },
    },
    kubeVersion: 'v1.18.0',
    noHooks: false,
  }),

  local datasource = grafana.datasource,
  prometheus_datasource:: datasource.new('prometheus', prometheusUrl, type='prometheus', default=false),
  loki_datasource:: datasource.new('loki', lokiGatewayUrl, type='loki', default=true) +
                    datasource.withBasicAuth('team-l', '${PROVISONING_TOKEN_GRAFANA_L}'),

  grafana: grafana
           + grafana.withAnonymous()
           + grafana.withImage('grafana/grafana-enterprise:8.2.5')
           + grafana.withGrafanaIniConfig({
             sections+: {
               server+: {
                 http_port: 3000,
               },
               users+: {
                 default_theme: 'light',
               },
               paths+: {
                 provisioning: '/etc/grafana/provisioning',
               },
             },
           })
           + grafana.withEnterpriseLicenseText(importstr '../../secrets/grafana.jwt')
           + grafana.addDatasource('prometheus', $.prometheus_datasource)
           + grafana.addDatasource('loki', $.loki_datasource)
           + {
             local container = k.core.v1.container,
             grafana_deployment+:
               k.apps.v1.deployment.hostVolumeMount(
                 name='enterprise-logs-app',
                 hostPath='/var/lib/grafana/plugins/grafana-enterprise-logs-app/dist',
                 path='/grafana-enterprise-logs-app',
                 volumeMixin=k.core.v1.volume.hostPath.withType('Directory')
               )
               + k.apps.v1.deployment.emptyVolumeMount('grafana-var', '/var/lib/grafana')
               + k.apps.v1.deployment.emptyVolumeMount('grafana-plugins', '/etc/grafana/provisioning/plugins')
               + k.apps.v1.deployment.spec.template.spec.withInitContainersMixin([
                 container.new('startup', 'alpine:latest') +
                 container.withCommand([
                   '/bin/sh',
                   '-euc',
                   |||
                     mkdir -p /var/lib/grafana/plugins
                     cp -r /grafana-enterprise-logs-app /var/lib/grafana/plugins/grafana-enterprise-logs-app
                     chown -R 472:472 /var/lib/grafana/plugins

                     cat > /etc/grafana/provisioning/plugins/enterprise-logs.yaml <<EOF
                     apiVersion: 1
                     apps:
                       - type: grafana-enterprise-logs-app
                         jsonData:
                           backendUrl: %s
                           base64EncodedAccessTokenSet: true
                         secureJsonData:
                           base64EncodedAccessToken: "$$(echo -n ":$$GEL_ADMIN_TOKEN" | base64 | tr -d '[:space:]')"
                     EOF
                   ||| % lokiGatewayUrl,
                 ]) +
                 container.withVolumeMounts([
                   k.core.v1.volumeMount.new('enterprise-logs-app', '/grafana-enterprise-logs-app', false),
                   k.core.v1.volumeMount.new('grafana-var', '/var/lib/grafana', false),
                   k.core.v1.volumeMount.new('grafana-plugins', '/etc/grafana/provisioning/plugins', false),
                 ]) +
                 container.withImagePullPolicy('IfNotPresent') +
                 container.mixin.securityContext.withPrivileged(true) +
                 container.mixin.securityContext.withRunAsUser(0) +
                 container.mixin.withEnv([
                   envVar.fromSecretRef('GEL_ADMIN_TOKEN', adminTokenSecret, 'token'),
                 ]),
               ]) + k.apps.v1.deployment.mapContainers(
                 function(c) c {
                   env+: [
                     envVar.new('GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS', 'grafana-enterprise-logs-app'),
                     envVar.fromSecretRef('PROVISONING_TOKEN_GRAFANA_L', provisionerSecret, 'token-grafana-l'),
                   ],
                 }
               ),
           },
}
