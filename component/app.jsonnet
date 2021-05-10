local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.csi_driver_smb;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('csi-driver-smb', params.namespace);

{
  'csi-driver-smb': app,
}
