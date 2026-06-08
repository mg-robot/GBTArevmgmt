import { LightningElement, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { getListRecordsByName } from "lightning/uiListsApi";

import getPromoCodeListViews from "@salesforce/apex/PromoCodeListViewService.getPromoCodeListViews";

const OBJECT_API_NAME = "Promo_Code__c";
const PAGE_SIZE = 20;

const COLUMNS = [
  {
    label: "Promo Code Name",
    fieldName: "recordUrl",
    type: "url",
    typeAttributes: { label: { fieldName: "Name" }, target: "_self" },
    wrapText: false
  },
  { label: "Code", fieldName: "Code__c" },
  { label: "Display Name", fieldName: "Display_Name__c" },
  { label: "Status", fieldName: "Status__c" },
  { label: "Discount Type", fieldName: "Discount_Type__c" },
  { label: "Discount", fieldName: "discountDisplay" },
  { label: "Currency", fieldName: "CurrencyIsoCode" },
  {
    label: "Effective Start",
    fieldName: "Effective_Start_Date__c",
    type: "date"
  },
  { label: "Effective End", fieldName: "Effective_End_Date__c", type: "date" }
];

const FIELDS_TO_FETCH = [
  "Promo_Code__c.Id",
  "Promo_Code__c.Name",
  "Promo_Code__c.Code__c",
  "Promo_Code__c.Display_Name__c",
  "Promo_Code__c.Status__c",
  "Promo_Code__c.Discount_Type__c",
  "Promo_Code__c.Discount_Value__c",
  "Promo_Code__c.CurrencyIsoCode",
  "Promo_Code__c.Effective_Start_Date__c",
  "Promo_Code__c.Effective_End_Date__c"
];

/**
 * Promotions Home list view section. Provides view switching, navigation to the
 * standard list view manager (where new views can be created), and an inline
 * record table with token-based pagination. Replaces flexipage:filterListCard
 * because that component locks to a single filter and does not allow inline
 * view switching on App Pages.
 */
export default class PromoCodeListSection extends NavigationMixin(
  LightningElement
) {
  columns = COLUMNS;
  viewOptions = [];
  selectedView;
  records = [];
  isLoading = true;

  // Pagination state. `pageToken` is the token sent to the wire adapter for the
  // current page; null fetches the first page. `nextPageToken` /
  // `previousPageToken` come from the response and drive Next/Previous.
  pageToken = null;
  nextPageToken = null;
  previousPageToken = null;
  pageIndex = 1;

  @wire(getPromoCodeListViews)
  wiredViews({ data, error }) {
    if (data) {
      this.viewOptions = data.map((v) => ({
        label: v.label,
        value: v.developerName
      }));
      if (!this.selectedView && this.viewOptions.length > 0) {
        const allView = this.viewOptions.find((v) => v.value === "All");
        this.selectedView = allView ? allView.value : this.viewOptions[0].value;
      }
    } else if (error) {
      console.error("getPromoCodeListViews error", error);
    }
  }

  @wire(getListRecordsByName, {
    objectApiName: OBJECT_API_NAME,
    listViewApiName: "$selectedView",
    pageSize: PAGE_SIZE,
    pageToken: "$pageToken",
    fields: FIELDS_TO_FETCH
  })
  wiredRecords({ data, error }) {
    if (data) {
      const recs = data.records || [];
      this.records = recs.map((r) => {
        const f = r.fields || {};
        const valOf = (name) => {
          const field = f[name];
          return field && field.value !== undefined ? field.value : "";
        };
        const discountType = valOf("Discount_Type__c");
        const discountValue = valOf("Discount_Value__c");
        let discountDisplay = "";
        if (discountValue !== "" && discountValue != null) {
          discountDisplay =
            discountType === "Percent"
              ? `${discountValue}%`
              : String(discountValue);
        }
        return {
          Id: r.id,
          Name: valOf("Name"),
          Code__c: valOf("Code__c"),
          Display_Name__c: valOf("Display_Name__c"),
          Status__c: valOf("Status__c"),
          Discount_Type__c: discountType,
          Discount_Value__c: discountValue,
          discountDisplay,
          CurrencyIsoCode: valOf("CurrencyIsoCode"),
          Effective_Start_Date__c: valOf("Effective_Start_Date__c"),
          Effective_End_Date__c: valOf("Effective_End_Date__c"),
          recordUrl: "/" + r.id
        };
      });
      this.nextPageToken = data.nextPageToken || null;
      this.previousPageToken = data.previousPageToken || null;
      this.isLoading = false;
    } else if (error) {
      this.records = [];
      this.nextPageToken = null;
      this.previousPageToken = null;
      this.isLoading = false;
      console.error("getListRecordsByName error", error);
    }
  }

  get hasViews() {
    return this.viewOptions.length > 0;
  }

  get hasRecords() {
    return this.records.length > 0;
  }

  get showEmptyState() {
    return !this.isLoading && this.records.length === 0;
  }

  get isPreviousDisabled() {
    return this.isLoading || !this.previousPageToken;
  }

  get isNextDisabled() {
    return this.isLoading || !this.nextPageToken;
  }

  get paginationLabel() {
    const start = (this.pageIndex - 1) * PAGE_SIZE + 1;
    const end = start + this.records.length - 1;
    return `Showing ${start}-${end}`;
  }

  handleViewChange(e) {
    this.selectedView = e.detail.value;
    this.pageToken = null;
    this.pageIndex = 1;
    this.isLoading = true;
  }

  handleManageViews() {
    this[NavigationMixin.Navigate]({
      type: "standard__objectPage",
      attributes: {
        objectApiName: OBJECT_API_NAME,
        actionName: "list"
      },
      state: {
        filterName: this.selectedView || "All"
      }
    });
  }

  handleRefresh() {
    // refreshApex returns undefined for UI API wire adapters (getListRecordsByName
    // refreshApex returns undefined for UI API wire adapters (getListRecordsByName
    // is not Apex-backed), so we force re-execution by toggling the reactive param.
    // setTimeout(0) is required — Promise.resolve().then() is a microtask and runs
    // before LWC's render cycle, so both assignments collapse into a single render
    // with no net change and the wire never re-fires.
    this.isLoading = true;
    const currentView = this.selectedView;
    this.selectedView = undefined;
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      this.selectedView = currentView;
    }, 0);
  }

  handleNext() {
    if (!this.nextPageToken) return;
    this.isLoading = true;
    this.pageToken = this.nextPageToken;
    this.pageIndex += 1;
  }

  handlePrevious() {
    if (!this.previousPageToken) return;
    this.isLoading = true;
    this.pageToken = this.previousPageToken;
    this.pageIndex = Math.max(1, this.pageIndex - 1);
  }
}
