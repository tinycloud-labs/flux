# Restoring a Proxmox CSI volume from VolSync

Backups are restic repositories on the NAS backend and are written nightly by the `ReplicationSource` next to each app (e.g. `apps/jellyfin/backup.yaml`).

Proxmox CSI PVCs here are pinned to a specific zvol (`existingVolume.handle`), so a restore is a deliberately manual step.

## Backup restore procedure (when the zvol is gone, e.g. lost zfs `tank` pool)

Example: Jellyfin, PVC `jellyfin-config-csi`.

1. Stop the app so it doesn't start on an empty disk:
   `flux suspend helmrelease jellyfin -n apps` and `kubectl scale deploy/jellyfin -n apps --replicas=0`.
2. Remove the stale objects that still point at the missing zvol:
   `kubectl delete pvc jellyfin-config-csi -n apps` then `kubectl delete pv jellyfin-config-csi`.
3. Unpin the dead disk and recreate the PVC. In `apps/jellyfin/release.yaml`, set
   `existingVolume.handle: ""` on the `jellyfin-config-csi` release, push, then
   `flux reconcile helmrelease jellyfin-config-csi -n apps --force`. The PVC comes back
   Pending; the Proxmox CSI driver creates a new, empty zvol on `tank` once a pod uses it
   (the restore mover in step 4 is that pod).
4. Restore into it. Apply a one-off `ReplicationDestination` (don't commit this resource, it would overwrite
   live data on every fresh cluster):

```yaml
   apiVersion: volsync.backube/v1alpha1
   kind: ReplicationDestination
   metadata:
     name: jellyfin-config-restore
     namespace: apps
   spec:
     trigger:
       manual: restore-1          # change the value to run it again
     restic:
       repository: volsync-jellyfin-config
       destinationPVC: jellyfin-config-csi
       copyMethod: Direct
       # previous: 1              # restore one backup older than the latest
       # restoreAsOf: "2026-11-01T00:00:00Z"
       moverVolumes:
         - mountPath: repo
           volumeSource:
             persistentVolumeClaim:
               claimName: volsync-repo
       moverSecurityContext:
         runAsUser: 0
         runAsGroup: 0
```

   Wait until `kubectl get replicationdestination jellyfin-config-restore -n apps -o jsonpath='{.status.lastManualSync}'`
   prints `restore-1`, then delete the `ReplicationDestination`.
5. Start the app `flux resume helmrelease jellyfin -n apps`.
6. Pin the new disk copy the new PV's `spec.csi.volumeHandle` into
   `existingVolume.handle`, as after a first install.

Nightly backups continue into the same repository; older snapshots are kept per the `retain` policy.

## Adding another PVC

1. Add a `BitwardenSecret` in `bootstrap/bw-secrets/volsync.yaml` with `RESTIC_REPOSITORY=/mnt/repo/<pvc>`
   and the shared `RESTIC_PASSWORD` (note: without this password, backups can't be restored).
2. Copy `apps/jellyfin/backup.yaml` next to the app, and change `sourcePVC`, `repository` and the
   `moverAffinity` label selector to match the pod that mounts the PVC.
