using './main.bicep'

param org = 'iic'
param lab_token = 'nic26'
param location = 'eastus'
param location_short = 'eus'
param tenant_id = '00000000-0000-0000-0000-000000000000'
param subscription_id_avd = '00000000-0000-0000-0000-000000000000'
param tags = {
  lab: 'nic26'
}
param names = {
  rg_arc: 'example-rg-arc'
  rg_control: 'example-rg-control'
  rg_mon: 'example-rg-mon'
  hostpool_hybrid: 'example-hp-hybrid'
  hostpool_identity: 'example-id-hostpool'
  dcr_avd_insights: 'example-dcr-avd-insights'
  dcr_assoc: 'example-dcra-avd-hybrid'
  arc_onboard_spn: 'example-sp-arc-onboard'
  kv_ops: 'example-kv-ops'
  fslogix_sa: 'examplefslogix'
  sessionhost_hv01: 'example-hv01'
  sessionhost_hv02: 'example-hv02'
}
param cluster_name = 'example-clus01'
param hybrid_csv_path = 'C:\\ClusterStorage\\example-vmstore-01'
param compute_switch_name = 'ConvergedSwitch(compute)'
param hybrid_vlan_id = 100
param hybrid_vcpu = 4
param hybrid_memory_gb = 16
param hybrid_disk_gb = 128
param hybrid_vms = [
  {
    name: 'example-hv01'
    owner_node: 'example-n01'
    mac_address: '00-15-5D-00-00-01'
    ip_address: '192.0.2.11'
  }
  {
    name: 'example-hv02'
    owner_node: 'example-n02'
    mac_address: '00-15-5D-00-00-02'
    ip_address: '192.0.2.12'
  }
]
param arc_tags = {
  realm: 'hybrid'
}
param dhcp_reservations = []
param hybrid_image_vhdx = 'images\\example-win11.vhdx'
param dns_resolver_inbound_ip = '192.0.2.53'
param secondary_dns_ip = '192.0.2.54'
param registration_token_ttl_hours = 2
param share_names = {
  profiles: 'example-profiles'
  odfc: 'example-odfc'
}
param shortpath_managed_port = 3390
param patch_channel = 'intune'
param dcr_avd_insights_id = ''
param hostpool_identity_principal_id = ''
param enable_arc_extensions = false
param manage_arc_rg_rbac = false
param assign_vm_login_roles = true
param group_object_ids = {
  avd_users: '00000000-0000-0000-0000-000000000000'
  avd_admins: '00000000-0000-0000-0000-000000000000'
}
param arc_onboard_sp_object_id = ''
param secret_name_prefix = 'example-'
