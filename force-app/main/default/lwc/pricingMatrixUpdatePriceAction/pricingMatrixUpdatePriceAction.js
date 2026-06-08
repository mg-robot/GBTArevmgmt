import { LightningElement, api } from "lwc";
import { CloseActionScreenEvent } from "lightning/actions";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";

export default class PricingMatrixUpdatePriceAction extends LightningElement {
  @api recordId;

  get flowInputVariables() {
    return [{ name: "recordId", type: "String", value: this.recordId }];
  }

  async handleStatusChange(event) {
    const status = event.detail.status;
    if (status === "FINISHED" || status === "FINISHED_SCREEN") {
      await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
      this.dispatchEvent(new CloseActionScreenEvent());
    }
  }
}
