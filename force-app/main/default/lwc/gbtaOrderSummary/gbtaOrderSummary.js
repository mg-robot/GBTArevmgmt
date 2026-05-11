import { LightningElement, api, wire } from "lwc";
import { gql, graphql, refresh } from "lightning/graphql";
import labelTitle from "@salesforce/label/c.OrderSummary_Title";
import labelBackLink from "@salesforce/label/c.OrderSummary_BackLink";
import labelLoadError from "@salesforce/label/c.OrderSummary_LoadError";
import labelEmptyMessage from "@salesforce/label/c.OrderSummary_EmptyMessage";
import labelSubtotalLabel from "@salesforce/label/c.OrderSummary_SubtotalLabel";
import labelTaxLabel from "@salesforce/label/c.OrderSummary_TaxLabel";
import labelTotalLabel from "@salesforce/label/c.OrderSummary_TotalLabel";

export default class GbtaOrderSummary extends LightningElement {
  labels = {
    title: labelTitle,
    backLink: labelBackLink,
    loadError: labelLoadError,
    emptyMessage: labelEmptyMessage,
    subtotalLabel: labelSubtotalLabel,
    taxLabel: labelTaxLabel,
    totalLabel: labelTotalLabel
  };
  @api orderId;
  lineItems = [];
  order;
  isLoading = true;
  error;
  isTaxBreakdownOpen = false;
  graphqlResult;

  @wire(graphql, {
    query: gql`
      query getOrderSummary($orderId: ID!) {
        uiapi {
          query {
            OrderItem(where: { OrderId: { eq: $orderId } }) {
              edges {
                node {
                  Id
                  Quantity {
                    value
                  }
                  UnitPrice {
                    value
                  }
                  TotalPrice {
                    value
                  }
                  Product2 {
                    Name {
                      value
                    }
                    Description {
                      value
                    }
                  }
                }
              }
            }
            Order(where: { Id: { eq: $orderId } }) {
              edges {
                node {
                  OrderNumber {
                    value
                  }
                  CurrencyIsoCode {
                    value
                  }
                  TotalAmount {
                    value
                  }
                  TotalTaxAmount {
                    value
                  }
                  GrandTotalAmount {
                    value
                  }
                  Status {
                    value
                  }
                }
              }
            }
          }
        }
      }
    `,
    variables: "$graphqlVariables"
  })
  graphqlQueryResult(result) {
    this.graphqlResult = result;
    const { data, errors } = result;
    if (data?.uiapi?.query) {
      this.isLoading = false;
      const currency =
        data.uiapi.query.Order.edges[0]?.node?.CurrencyIsoCode?.value ?? "USD";
      this.lineItems = data.uiapi.query.OrderItem.edges.map((edge) => ({
        Id: edge.node.Id,
        Quantity: edge.node.Quantity.value,
        UnitPrice: edge.node.UnitPrice.value,
        TotalPrice: edge.node.TotalPrice.value,
        ProductName: edge.node.Product2.Name.value,
        formattedPrice: this._formatCurrency(
          edge.node.TotalPrice.value,
          currency
        )
      }));
      const orderNode = data.uiapi.query.Order.edges[0]?.node;
      if (orderNode) {
        this.order = {
          OrderNumber: orderNode.OrderNumber.value,
          CurrencyIsoCode: orderNode.CurrencyIsoCode.value,
          TotalAmount: orderNode.TotalAmount.value,
          TotalTaxAmount: orderNode.TotalTaxAmount.value,
          GrandTotalAmount: orderNode.GrandTotalAmount.value,
          Status: orderNode.Status.value
        };
      }
      this.error = undefined;
    } else if (errors) {
      this.isLoading = false;
      this.error = errors;
    }
  }

  @api
  refresh() {
    refresh(this.graphqlResult);
  }

  get graphqlVariables() {
    if (!this.orderId) return undefined;
    return { orderId: this.orderId };
  }

  get hasItems() {
    return this.lineItems && this.lineItems.length > 0;
  }

  get itemCountLabel() {
    const count = this.lineItems?.length ?? 0;
    return `${count} item${count !== 1 ? "s" : ""}`;
  }

  get formattedSubtotal() {
    return this._formatCurrency(
      this.order?.TotalAmount ?? 0,
      this.order?.CurrencyIsoCode ?? "USD"
    );
  }

  get formattedTax() {
    return this._formatCurrency(
      this.order?.TotalTaxAmount ?? 0,
      this.order?.CurrencyIsoCode ?? "USD"
    );
  }

  get formattedTotal() {
    return this._formatCurrency(
      this.order?.GrandTotalAmount ?? 0,
      this.order?.CurrencyIsoCode ?? "USD"
    );
  }

  get hasTax() {
    return (this.order?.TotalTaxAmount ?? 0) > 0;
  }

  get taxBreakdownIcon() {
    return this.isTaxBreakdownOpen
      ? "utility:chevronup"
      : "utility:chevrondown";
  }

  handleTaxToggle() {
    this.isTaxBreakdownOpen = !this.isTaxBreakdownOpen;
  }

  _formatCurrency(value, currencyCode = "USD") {
    return new Intl.NumberFormat("en-US", {
      style: "currency",
      currency: currencyCode
    }).format(value || 0);
  }
}