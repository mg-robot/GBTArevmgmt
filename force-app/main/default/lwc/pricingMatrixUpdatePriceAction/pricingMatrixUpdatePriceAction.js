import { LightningElement, api, track } from "lwc";
import { CloseActionScreenEvent } from "lightning/actions";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";

export default class PricingMatrixUpdatePriceAction extends LightningElement {
  @track _showFlow = false;
  _recordId;

  @api
  get recordId() {
    return this._recordId;
  }
  set recordId(value) {
    // Set once — ignore null/undefined resets from the platform
    if (value && !this._recordId) {
      this._recordId = value;
      this._showFlow = true;
    }
  }

  get showFlow() {
    return this._showFlow;
  }

  get flowInputVariables() {
    if (!this._recordId) return [];
    return [{ name: "recordId", type: "String", value: this._recordId }];
  }

  async handleStatusChange(event) {
    const status = event.detail.status;
    if (status === "FINISHED" || status === "FINISHED_SCREEN") {
      await notifyRecordUpdateAvailable([{ recordId: this._recordId }]);
      this.dispatchEvent(new CloseActionScreenEvent());
    }
  }
}
