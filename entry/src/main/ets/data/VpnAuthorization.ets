import { vpnExtension } from '@kit.NetworkKit';

export class VpnAuthorization {
  // API 26 on the test device crashes in CreateVpnObserver's native finalizer
  // during idle GC. Retain exactly one observer for the UI process lifetime.
  // Unsubscribe the callback after each attempt; never discard the observer.
  private static observer?: vpnExtension.VpnObserver;

  static subscribe(callback: (authorized: boolean) => void): void {
    if (!VpnAuthorization.observer) {
      VpnAuthorization.observer = vpnExtension.createVpnObserver();
    }
    VpnAuthorization.observer.onAuthorizationResult(callback);
  }

  static unsubscribe(): void {
    VpnAuthorization.observer?.offAuthorizationResult();
  }
}
