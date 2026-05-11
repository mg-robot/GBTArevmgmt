import { LightningElement, api, wire } from "lwc";
import { CurrentPageReference } from "lightning/navigation";
import getOrderDetails from "@salesforce/apex/GbtaCheckoutController.getOrderDetails";
import { refreshApex } from "@salesforce/apex";
import labelLoadError from "@salesforce/label/c.Checkout_LoadError";
import labelPageTitle from "@salesforce/label/c.Checkout_PageTitle";
import labelSuccessHeading from "@salesforce/label/c.Checkout_SuccessHeading";
import labelSuccessMessage from "@salesforce/label/c.Checkout_SuccessMessage";
import labelNeedsReviewHeading from "@salesforce/label/c.Checkout_NeedsReviewHeading";
import labelNeedsReviewMessage from "@salesforce/label/c.Checkout_NeedsReviewMessage";

export default class GbtaCheckout extends LightningElement {
  labels = {
    loadError: labelLoadError,
    pageTitle: labelPageTitle,
    successHeading: labelSuccessHeading,
    successMessage: labelSuccessMessage,
    needsReviewHeading: labelNeedsReviewHeading,
    needsReviewMessage: labelNeedsReviewMessage
  };

  isOrderComplete = false;
  isNeedsReview = false;
  orderNumber = "";
  _orderData;
  isLoading = true;
  resolvedOrderId;
  _apiOrderId;
  _wiredError;
  _wiredOrderDetailsResult;

  @api
  get orderId() {
    return this._apiOrderId;
  }
  set orderId(value) {
    this._apiOrderId = value;
    this._updateResolvedOrderId();
  }

  @wire(CurrentPageReference)
  handlePageRef(pageRef) {
    this._pageRef = pageRef;
    this._updateResolvedOrderId();
  }

  _updateResolvedOrderId() {
    const resolved =
      this._apiOrderId ||
      this._pageRef?.state?.orderId ||
      this._pageRef?.state?.orderid;

    this.resolvedOrderId = resolved;

    if (resolved) {
      this._wiredError = undefined;
    } else if (this._pageRef) {
      this._wiredError = { message: "No order ID provided." };
      this.isLoading = false;
    }
  }

  @wire(getOrderDetails, { orderId: "$resolvedOrderId" })
  wiredOrderDetails(result) {
    this._wiredOrderDetailsResult = result;
    const { data, error } = result;
    if (data) {
      this._orderData = data;
      this.isLoading = false;
      if (data.isAlreadyPaid || (data.grandTotalAmount ?? 1) <= 0) {
        this.isOrderComplete = true;
        this.orderNumber = data.orderNumber;
        this.isNeedsReview = data.isNeedsReview === true;
      }
    } else if (error) {
      this._wiredError = error;
      this.isLoading = false;
    }
  }

  get successHeading() {
    return this.isNeedsReview
      ? this.labels.needsReviewHeading
      : this.labels.successHeading;
  }

  get successMessage() {
    return this.isNeedsReview
      ? this.labels.needsReviewMessage
      : this.labels.successMessage;
  }

  handleVatApplied() {
    const summary = this.template.querySelector("c-gbta-order-summary");
    if (summary) {
      summary.refresh();
    }
    refreshApex(this._wiredOrderDetailsResult);
  }

  handlePaymentSuccess() {
    this.isOrderComplete = true;
    this.isNeedsReview = this._orderData?.isNeedsReview === true;
    this.orderNumber =
      this._orderData?.orderNumber ??
      `GBTA-${new Date().getFullYear()}-${String(Date.now()).slice(-5)}`;
  }
}