// main template for csi-driver-smb
local com = import 'lib/commodore.libjsonnet';
local espejo = import 'lib/espejo.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.csi_driver_smb;

local volumes = [
  kube.PersistentVolume(pv.name) +
  params.pvTemplate +
  {
    spec+: {
      storageClassName: 'smb-%s' % [ pv.namespace ],
      csi+: {
        volumeAttributes: {
          source: '//%s/%s' % [ pv.share_host, pv.share_name ],
        },
        volumeHandle: 'pv-%s-%s' % [ pv.namespace, pv.name ],
        nodeStageSecretRef: {
          name: '%s-credentials' % [ pv.name ],
          namespace: pv.namespace,
        },
      },
    },
  } +
  com.getValueOrDefault(pv, 'pvOverrides', {})

  for pv in params.volumes
];

local claims = [
  kube.PersistentVolumeClaim(pv.name) +
  params.pvcTemplate +
  {
    metadata+: {
      namespace: pv.namespace,
    },
    spec+: {
      storageClassName: 'smb-%s' % [ pv.namespace ],
      volumeMode: 'Filesystem',
      volumeName: pv.name,
    },
  } +
  com.getValueOrDefault(pv, 'pvcOverrides', {})

  for pv in std.filter(function(i) !!i.createClaim, params.volumes)
];

local pvSecrets = [
  kube.Secret(pv.name + '-credentials') {
    metadata+: {
      namespace: pv.namespace,
    },
    // need to use stringData here for secret reveal to work
    // use keys which the csi-driver expects for the credentials secret
    stringData+: {
      username: pv.username,
      password: pv.password,
    },
  }
  for pv in params.volumes
];

local commonItemLabels = {
  'app.kubernetes.io/managed-by': 'espejo',
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'csi-driver-smb',
};

local syncConfigs = [
  espejo.syncConfig('restrict-smb-' + pv.namespace) {
    spec: {
      forceRecreate: true,
      namespaceSelector: {
        labelSelector: {
          matchExpressions: [ {
            key: pv.name,
            operator: 'NotIn',
            values: [ pv.namespace ],
          } ],
        },
      },
      syncItems: [ {
        apiVersion: 'v1',
        kind: 'ResourceQuota',
        metadata: {
          name: 'restrict-smb-%s' % [ pv.namespace ],
          labels: commonItemLabels,
        },
        spec: {
          hard: {
            ['smb-%s.storageclass.storage.k8s.io/persistentvolumeclaims' % pv.namespace]: '0',
          },
        },
      } ],
    },
  }
  for pv in params.volumes
];

{
  '01_syncConfigs': syncConfigs,
  '02_pvSecrets': pvSecrets,
  '03_pvs': std.prune(volumes),
  '04_pvcs': std.prune(claims),
  '05_serviceaccount': kube.ServiceAccount('csi-smb-controller-sa') {
    metadata+: {
      namespace: params.namespace,
    },
  },
}
