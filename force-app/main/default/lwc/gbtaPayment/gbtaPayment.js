import { LightningElement, api } from "lwc";
import initializePayment from "@salesforce/apex/GbtaCheckoutController.initializePayment";
import labelLoadingText from "@salesforce/label/c.Payment_LoadingText";
import labelInitError from "@salesforce/label/c.Payment_InitError";

export default class GbtaPayment extends LightningElement {
  labels = {
    loadingText: labelLoadingText,
    initError: labelInitError
  };

  _orderId;
  gatewayId;
  chargentOrderId;
  isLoading = true;
  error;

  @api
  get orderId() {
    return this._orderId;
  }
  set orderId(value) {
    this._orderId = value;
    if (value) {
      this._initialize();
    }
  }

  _initialize() {
    initializePayment({ orderId: this._orderId })
      .then((result) => {
        this.gatewayId = result.gatewayId;
        this.chargentOrderId = result.chargentOrderId;
        this.isLoading = false;
      })
      .catch((err) => {
        this.error =
          err?.body?.message ?? err?.message ?? this.labels.initError;
        this.isLoading = false;
      });
  }

  handlePaymentComplete(event) {
    if (event?.detail?.result !== "success") return;
    this.dispatchEvent(
      new CustomEvent("paymentsuccess", {
        bubbles: false,
        detail: { orderId: this._orderId }
      })
    );
  }
}