// main template for csi-driver-smb
local com = import 'lib/commodore.libjsonnet';
local espejo = import 'lib/espejo.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.csi_driver_smb;

local isOpenShift = std.startsWith(inv.parameters.facts.distribution, 'openshift');

local namespace =
  kube.Namespace(params.namespace)
  {
    metadata+: {
      annotations+: {
        // Allow Pods to be scheduled on any Node
        [if isOpenShift then 'openshift.io/node-selector']: '',
      },
    },
  };

local rolebinding = if isOpenShift then
  kube.RoleBinding('privileged')
  {
    metadata+: {
      namespace: params.namespace,
    },
    roleRef_: {
      kind: 'ClusterRole',
      metadata: {
        name: 'system:openshift:scc:privileged',
      },
    },
    subjects_: [
      {
        kind: 'ServiceAccount',
        metadata: {
          name: sa,
          namespace: params.namespace,
        },
      }
      for sa in [
        params.helmValues.serviceAccount.controller,
        params.helmValues.serviceAccount.node,
      ]
    ],
  };

local volumes = [
  local volume =
    kube.PersistentVolume(pv.name) +
    params.pvTemplate +
    {
      spec+: {
        storageClassName: 'smb-%s' % [ pv.namespace ],
        csi+: {
          volumeAttributes+: {
            source: '//%s/%s' % [ pv.shareHost, pv.shareName ],
          },
          volumeHandle: 'pv-%s-%s' % [ pv.namespace, pv.name ],
          nodeStageSecretRef+: {
            name: '%s-credentials' % [ pv.name ],
            namespace: pv.namespace,
          },
        },
      },
    };

  std.mergePatch(volume, com.getValueOrDefault(pv, 'pvPatch', {}))

  for pv in params.volumes
];

local claims = [
  local claim =
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
    };

  std.mergePatch(claim, com.getValueOrDefault(pv, 'pvcPatch', {}))

  for pv in std.filter(function(i) com.getValueOrDefault(i, 'createClaim', false), params.volumes)
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

local nameField = function(i) i.metadata.name;

// Items in an array must be sorted before calling `uniq`.
local syncConfigs = std.uniq(std.sort([
  espejo.syncConfig('restrict-smb-' + pv.namespace) {
    spec: {
      forceRecreate: true,
      namespaceSelector: {
        ignoreNames: [ pv.namespace ],
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
], nameField), nameField);

{
  '00_namespace': namespace,
  '01_syncConfigs': syncConfigs,
  '02_pvSecrets': pvSecrets,
  '03_pvs': std.prune(volumes),
  '04_pvcs': std.prune(claims),
  [if rolebinding != null then '05_rolebinding']: rolebinding,
}
