// main template for csi-driver-smb
local com = import 'lib/commodore.libjsonnet';
local espejo = import 'lib/espejo.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.csi_driver_smb;

local defaultMountOptions = [
  'dir_mode=0777',
  'file_mode=0777',
  'vers=3.0',
];

local pvs = [
  kube.PersistentVolume(pv.name) {
    spec+: {
      capacity: {
        storage: pv.capacity,
      },
      accessModes: com.getValueOrDefault(pv, 'accessModes', [ 'ReadWriteMany' ],),
      persistentVolumeReclaimPolicy: com.getValueOrDefault(pv, 'reclaimPolicy', null),
      mountOptions: com.getValueOrDefault(pv, 'mountOptions', defaultMountOptions),
      csi: {
        driver: 'smb.csi.k8s.io',
        readOnly: com.getValueOrDefault(pv, 'readOnly', null),
        volumeAttributes: {
          source: '//%s/%s' % [ pv.share_host, pv.share_name ],
        },
        volumeHandle: 'pv-%s-%s' % [ pv.namespace, pv.name ],
        nodeStageSecretRef: {
          name: '%s-credentials' % [ pv.name ],
          namespace: pv.namespace,
        },
      },
      storageClassName: 'smb-%s' % [ pv.namespace ],
    },
  }
  for pv in params.pvs
];

local pvcs = [
  kube.PersistentVolumeClaim(pv.name) {
    metadata+: {
      namespace: pv.namespace,
    },
    spec+: {
      accessModes: com.getValueOrDefault(pv, 'accessModes', [ 'ReadWriteMany' ],),
      resources: {
        requests: {
          storage: pv.capacity,
        },
      },
      storageClassName: 'smb-%s' % [ pv.namespace ],
      volumeMode: 'Filesystem',
      volumeName: pv.name,
    },
  }
  for pv in params.pvs
];
local pvSecrets = [
  kube.Secret(pv.name + '-credentials') {
    metadata+: {
      namespace: pv.namespace,
    },
    // need to use stringData here for secret reveal to work
    // use keys which the csi-driver expects for the credentials secret
    stringData+: {
      username: pv.username_ref,
      password: pv.password_ref,
    },
  }
  for pv in params.pvs
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
  for pv in params.pvs
];

{
  '01_syncConfigs': syncConfigs,
  '02_pvSecrets': pvSecrets,
  '03_pvs': std.prune(pvs),
  '04_pvcs': std.prune(pvcs),
  '05_serviceaccount': kube.ServiceAccount('csi-smb-controller-sa') {
    metadata+: {
      namespace: params.namespace,
    },
  },
}
