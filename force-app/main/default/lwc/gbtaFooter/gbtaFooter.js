import { LightningElement, api, wire, track } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import basePath from '@salesforce/community/basePath';
import getNavigationMenuItems from '@salesforce/apex/NavigationMenuItemsController.getNavigationMenuItems';
import isGuestUser from '@salesforce/user/isGuest';

export default class GbtaFooter extends NavigationMixin(LightningElement) {
    @api column1MenuName;
    @api column1Title = 'Our Company';
    @api column2MenuName;
    @api column2Title = 'Get Help';
    @api column3MenuName;
    @api column3Title = 'Account';
    @api helpButtonLabel = 'Get Help & Support';
    @api helpButtonPageApiName;
    @api languageLabel = 'United States | EN';
    @api languagePageApiName;
    @api twitterUrl;
    @api facebookUrl;
    @api youtubeUrl;
    @api instagramUrl;
    @api footerLogoUrl;
    @api logoAlt = 'GBTA - Global Business Travel Association';
    @api copyrightText;

    @track column1Items = [];
    @track column2Items = [];
    @track column3Items = [];

    basePath = basePath;
    publishedState;

    @wire(CurrentPageReference)
    setCurrentPageReference(currentPageReference) {
        const app = currentPageReference?.state?.app;
        this.publishedState = app === 'commeditor' ? 'Draft' : 'Live';
    }

    @wire(getNavigationMenuItems, { menuName: '$column1MenuName', publishedState: '$publishedState' })
    wiredColumn1({ data, error }) {
        if (data) {
            this.resolveItems(data).then((items) => {
                this.column1Items = items;
            });
        } else if (error) {
            console.error('Footer column 1 nav error:', JSON.stringify(error));
        }
    }

    @wire(getNavigationMenuItems, { menuName: '$column2MenuName', publishedState: '$publishedState' })
    wiredColumn2({ data, error }) {
        if (data) {
            this.resolveItems(data).then((items) => {
                this.column2Items = items;
            });
        } else if (error) {
            console.error('Footer column 2 nav error:', JSON.stringify(error));
        }
    }

    @wire(getNavigationMenuItems, { menuName: '$column3MenuName', publishedState: '$publishedState' })
    wiredColumn3({ data, error }) {
        if (data) {
            this.resolveItems(data).then((items) => {
                this.column3Items = items;
            });
        } else if (error) {
            console.error('Footer column 3 nav error:', JSON.stringify(error));
        }
    }

    async resolveItems(rawData) {
        const filtered = rawData
            .map((item, index) => ({
                id: index,
                label: item.Label,
                target: item.Target,
                type: item.Type,
                defaultListViewId: item.DefaultListViewId,
                accessRestriction: item.AccessRestriction,
                computedHref: '#',
                pageReference: this.buildPageReference(item)
            }))
            .filter(
                (item) =>
                    item.accessRestriction === 'None' ||
                    (item.accessRestriction === 'LoginRequired' && !isGuestUser)
            );
        return Promise.all(
            filtered.map(async (item) => {
                if (item.pageReference) {
                    try {
                        item.computedHref = await this[NavigationMixin.GenerateUrl](
                            item.pageReference
                        );
                    } catch (e) {
                        // keep '#' fallback
                    }
                }
                return item;
            })
        );
    }

    buildPageReference(item) {
        const { Type: type, Target: target, DefaultListViewId: defaultListViewId } = item;
        if (type === 'SalesforceObject') {
            return {
                type: 'standard__objectPage',
                attributes: { objectApiName: target },
                state: { filterName: defaultListViewId }
            };
        }
        if (type === 'InternalLink') {
            return {
                type: 'standard__webPage',
                attributes: { url: basePath + target }
            };
        }
        if (type === 'ExternalLink') {
            return {
                type: 'standard__webPage',
                attributes: { url: target }
            };
        }
        return null;
    }

    handleHelpClick() {
        if (this.helpButtonPageApiName) {
            this[NavigationMixin.Navigate]({
                type: 'comm__namedPage',
                attributes: { name: this.helpButtonPageApiName }
            });
        }
    }

    handleLanguageClick() {
        if (this.languagePageApiName) {
            this[NavigationMixin.Navigate]({
                type: 'comm__namedPage',
                attributes: { name: this.languagePageApiName }
            });
        }
    }
}