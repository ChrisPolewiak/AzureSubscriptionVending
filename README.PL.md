# Azure Subscription Vending

Pipeline Azure DevOps do automatycznego przygotowania subskrypcji i umieszczania ich w strukturze Management Group.

## Co robi pipeline

1. Waliduje subskrypcję i parametry wejściowe
2. Zmienia nazwę subskrypcji i rejestruje wymaganych dostawców zasobów
3. Wdraża zasoby bootstrap (Resource Group + User Assigned Managed Identity) przy użyciu Bicep
4. Nadaje role bootstrap UAMI w zakresie subskrypcji
5. Tworzy Service Connection w Azure DevOps dla nowej subskrypcji *(opcjonalne)*
6. Przenosi subskrypcję do docelowego Management Group
7. Weryfikuje finalne umieszczenie

## Struktura repozytorium

```
.pipelines/subscription-vending.yml   # Pipeline Azure DevOps
bin/subscriptionVendingBootstrap.sh   # Skrypt bootstrap (bash)
bicep/bootstrap.bicep                 # Szablon Bicep dla zasobów bootstrap
parameters/subscriptionVending.json   # Grupy rejestracji providerów i definicje ról UAMI
SUBSCRIPTION_VENDING_RUNBOOK.md       # Instrukcja operatora: konfiguracja RBAC i checklist
```

## Wymagania wstępne

- Azure DevOps Managed Pool z dedykowanym UAMI
- UAMI z rolą **Management Group Contributor** na Root Management Group
- UAMI z rolami **Contributor** i **User Access Administrator** na staging Management Group
- Konto `[NazwaProjektu] Build Service` dodane do grupy **Endpoint Creators** w docelowym projekcie Azure DevOps

## Uruchamianie pipeline

Subskrypcja musi znajdować się w staging Management Group przed uruchomieniem pipeline. Pipeline przenosi ją do docelowego Management Group jako ostatni krok.

Parametry wymagane i opcjonalne:

| Parametr | Opis |
| --- | --- |
| `SubscriptionId` | ID subskrypcji do provisioningu |
| `SubscriptionName` | Nowa nazwa subskrypcji. |
| `SourceManagementGroupId` | Staging MG, w którym aktualnie znajduje się subskrypcja |
| `TargetManagementGroupId` | Docelowy MG, do którego subskrypcja zostanie przeniesiona |
| `BootstrapResourceGroupName` | Nazwa bootstrap Resource Group |
| `BootstrapManagedIdentityName` | Nazwa bootstrap UAMI |
| `ServiceConnectionName` | Nazwa Service Connection w Azure DevOps |
| `AzureDevOpsProjectName` | Docelowy projekt Azure DevOps |
| `CreateServiceConnection` | Czy tworzyć Service Connection automatycznie (domyślnie: `true`) |

---

## 1. Cel

Zautomatyzowane tworzenie subskrypcji w Azure wraz z minimalnym zestawem usług oraz umieszczeniem w odpowiednim Management Group.

Wymaganie wstępne:

- Rozwiązanie wymaga utworzenia dedykowanej gałęzi Management Group dla pustych subskrypcji (landing/staging), w której pipeline będzie wykonywał bootstrap i przypisania RBAC.

## 2. Działanie pipeline i wymagania

Pipeline jest uruchamiany w Azure DevOps na Managed Pool z dedykowanym UAMI (User Assigned Managed Identity). UAMI wykonuje operacje Azure (ARM), a operacje Azure DevOps API są wykonywane przez `$(System.AccessToken)` jako tożsamość Build Service projektu.

Zakres działań pipeline:

- tworzy i przygotowuje nową subskrypcję,
- wykonuje bootstrap (RG, UAMI, role),
- przenosi subskrypcję w strukturze Management Group,
- tworzy Service Connection w Azure DevOps do nowej subskrypcji.

Wymagania wynikające z działań pipeline:

| Obszar | Wymaganie |
| --- | --- |
| Azure RBAC (Root MG) | prawo przeniesienia subskrypcji do docelowej gałęzi MG |
| Azure RBAC (dedykowana gałąź MG z pustymi subskrypcjami) | prawo tworzenia zasobów i wykonywania bootstrap |
| Azure RBAC (dedykowana gałąź MG z pustymi subskrypcjami) | prawo nadawania ról Contributor i User Access Administrator |
| Azure RBAC (jakość przypisania) | User Access Administrator musi być pełny: "Allow user to assign all roles (highly privileged)" |
| Azure DevOps (projekt) | prawo utworzenia Service Connection do nowej subskrypcji |

## 3. Kolejność etapów w pipeline

Poniżej jest docelowa kolejność procesu (MOVE na końcu).

| Kolejność | Stage (pipeline) | Tryb skryptu | Co jest wykonywane |
| --- | --- | --- | --- |
| 1 | ValidateInput | `validate` | Walidacja wejścia i stanu: parametry, istnienie subskrypcji, istnienie source/target MG, obecność pliku Bicep, sprawdzenie czy subskrypcja jest w source lub target MG. |
| 2 | PrepareSubscription | `prepare` | Zmiana nazwy subskrypcji oraz rejestracja providerów z `parameters/subscriptionVending.json`. |
| 3 | BootstrapAzure | `bootstrap` | Deployment Bicep `bicep/bootstrap.bicep` na poziomie subskrypcji: utworzenie bootstrap RG oraz UAMI. |
| 4 | ConfigureAccess | `rbac` | Nadanie ról dla bootstrap UAMI na scope subskrypcji (`/subscriptions/<id>`) zgodnie z `parameters/subscriptionVending.json`. |
| 5 | ConfigureDevOps *(opcjonalny)* | `service-connection-manifest` | Przygotowanie i publikacja artefaktu `service-connection-manifest.json` dla utworzenia Service Connection (OIDC do UAMI). **Wymaga, aby konto Build Service projektu miało uprawnienia Endpoint Creators w projekcie Azure DevOps.** Jeśli konto Build Service nie ma tych uprawnień, stage jest pomijany (`CreateServiceConnection=false`) — operator tworzy Service Connection ręcznie korzystając z danych bootstrap (subscription ID, UAMI client ID, tenant ID). Plik `service-connection-manifest.json` jest dostępny jako artefakt pipeline (`subscription-vending-service-connection`) w zakładce Artifacts danego runu w Azure DevOps. |
| 6 | VerifyBootstrap | `verify-bootstrap` | Weryfikacja stanu po bootstrap: istnieją bootstrap RG i UAMI oraz przygotowany manifest Service Connection. |
| 7 | FinalMove | `move` | Finalne przeniesienie subskrypcji do docelowej gałęzi MG. |
| 8 | VerifyFinal | `verify-final` | Końcowa weryfikacja: subskrypcja znajduje się w docelowej gałęzi MG. |

## 4. Instrukcja krok po kroku: nadanie ról UAMI dla procesu subscription vending

**Cel: Zrealizować wymagania RBAC opisane w sekcji 2, aby pipeline mógł poprawnie wykonać provisioning, bootstrap i finalne przeniesienie subskrypcji.**

Zakres działania:

- nadać rolę Management Group Contributor na Root MG
- nadać rolę Contributor na dedykowanej gałęzi MG z pustymi subskrypcjami
- nadać rolę User Access Administrator na dedykowanej gałęzi MG z pustymi subskrypcjami

## 4.1 Przygotuj dane

Wartości wymagane:

- SUBSCRIPTION_ID - identyfikator subskrypcji, w której będzie działał pipeline
- UAMI_RESOURCE_GROUP - nazwa Resource Group, w której zostanie utworzony UAMI
- UAMI_NAME - np. "id-uami-subscription-vending"
- PRINCIPAL_ID - identyfikator principalId utworzonego UAMI
- ROOT_MG_ID - identyfikator Root Management Group
- EMPTY_SUBSCRIPTIONS_MG_ID - identyfikator dedykowanej gałęzi MG z pustymi subskrypcjami
- LOCATION - np. "germanywestcentral"

## 4.2 Utworzenie UAMI

Polecenia:

```bash
az identity create --name <UAMI_NAME> --resource-group <UAMI_RESOURCE_GROUP> --location <LOCATION>

az identity show --name <UAMI_NAME> --resource-group <UAMI_RESOURCE_GROUP> --query principalId -o tsv
```

Instrukcja manualna w portalu:

1. Przejdź do Resource Group w portalu Azure
2. Wybierz Resource Group, w której chcesz utworzyć UAMI
3. Kliknij Create
4. Wyszukaj User Assigned Managed Identity i kliknij Create
5. Uzupełnij Name i Region, kliknij Review + create, następnie Create
6. Otwórz utworzone UAMI i skopiuj Principal ID

## 4.3 Nadaj rolę na Root MG

Polecenie:

```bash
az role assignment create --assignee-object-id <PRINCIPAL_ID> --assignee-principal-type ServicePrincipal --role "Management Group Contributor" --scope "/providers/Microsoft.Management/managementGroups/<ROOT_MG_ID>"
```

Instrukcja manualna w portalu:

1. Przejdź do Management Group w portalu Azure
2. Wybierz Root MG
3. Wybierz Access Control (IAM)
4. Kliknij Add role assignment
5. Wybierz rolę Management Group Contributor
6. W Assign access to wybierz Managed identity
7. Wybierz User assigned managed identity i wskaż utworzony UAMI
8. Kliknij Review + assign

## 4.4 Nadaj role na gałęzi MG z pustymi subskrypcjami

Polecenia:

```bash
az role assignment create --assignee-object-id <PRINCIPAL_ID> --assignee-principal-type ServicePrincipal --role "Contributor" --scope "/providers/Microsoft.Management/managementGroups/<EMPTY_SUBSCRIPTIONS_MG_ID>"

az role assignment create --assignee-object-id <PRINCIPAL_ID> --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope "/providers/Microsoft.Management/managementGroups/<EMPTY_SUBSCRIPTIONS_MG_ID>"
```

Instrukcja manualna w portalu:

1. Przejdź do dedykowanej gałęzi MG z pustymi subskrypcjami w portalu Azure
2. Wybierz Access Control (IAM)
3. Kliknij Add role assignment
4. Wybierz rolę Contributor
5. W Assign access to wybierz Managed identity
6. Wybierz User assigned managed identity i wskaż utworzony UAMI
7. Kliknij Review + assign
8. Powtórz kroki 2-7 dla roli User Access Administrator
9. Upewnij się, że przypisanie User Access Administrator jest ustawione jako "Allow user to assign all roles (highly privileged)" (bez warunków/ograniczeń)

## 4.5 Zweryfikuj przypisania

Polecenie:

```bash
az role assignment list --assignee-object-id <PRINCIPAL_ID> --all --query "[].{role:roleDefinitionName,scope:scope}" -o table
```

Oczekiwany wynik:

- Management Group Contributor na Root MG
- Contributor na dedykowanej gałęzi MG z pustymi subskrypcjami
- User Access Administrator na dedykowanej gałęzi MG z pustymi subskrypcjami

## 5. Kolejny krok: nadanie uprawnień w Azure DevOps

**Cel: Zrealizować wymaganie z sekcji 2 dla Azure DevOps: pipeline ma móc utworzyć Service Connection do nowo utworzonej subskrypcji.**

### 5.1 Tożsamość tworząca Service Connection

Pipeline tworzy Service Connection przez REST API Azure DevOps używając tokenu `$(System.AccessToken)`. Ten token reprezentuje **wbudowane konto build service projektu** — nie UAMI z Managed Pool.

Nazwa konta ma format:
```
<ProjectName> Build Service (<OrgName>)
```
Przykład: `ProjectA Build Service (Contoso)`

> **Uwaga:** UAMI przypisane do Managed Pool jest używane do operacji na Azure (ARM). Do operacji na Azure DevOps API pipeline używa `$(System.AccessToken)` — to osobna tożsamość.

### 5.2 Nadanie uprawnień Endpoint Creators

**Minimalne uprawnienie to `Endpoint Creators`** — nie Project Administrators. Daje ono prawo tworzenia i przeglądania Service Connections w projekcie.

Dla każdego projektu Azure DevOps, w którym pipeline ma tworzyć Service Connections:

Instrukcja manualna:

1. Przejdź do projektu Azure DevOps.
2. Otwórz **Project settings → Service connections**.
3. Kliknij **Security** (ikonka kłódki w prawym górnym rogu).
4. Znajdź grupę **Endpoint Creators**.
5. Kliknij **Add** i wyszukaj `<ProjectName> Build Service (<OrgName>)`.
6. Zapisz zmiany.

Weryfikacja: konto Build Service widoczne jest w grupie Endpoint Creators danego projektu.

### 5.3 Nowe projekty

Przy tworzeniu każdego nowego projektu Azure DevOps, w którym będzie działał vending pipeline, należy powtórzyć krok 5.2 — dodać konto Build Service tego projektu do grupy Endpoint Creators.

### 5.4 Weryfikacja

Dla wybranego projektu:

```bash
az devops security group membership list \
  --group-id "[<PROJECT_NAME>]\Endpoint Creators" \
  --org "https://dev.azure.com/<ORG_NAME>" \
  --query "[].principalName" -o table
```

Oczekiwany wynik: konto `<ProjectName> Build Service (<OrgName>)` widoczne w liście.

## 6. Checklist przed pierwszym uruchomieniem

- dedykowane UAMI istnieje
- rola Management Group Contributor jest nadana na Root MG
- role Contributor i User Access Administrator są nadane na dedykowanej gałęzi MG z pustymi subskrypcjami
- rola User Access Administrator dla UAMI pipeline jest ustawiona jako "Allow user to assign all roles (highly privileged)" (bez warunków/ograniczeń)
- konto **`<ProjectName> Build Service (<OrgName>)`** jest dodane do grupy **Endpoint Creators** w każdym projekcie Azure DevOps, w którym pipeline tworzy Service Connections
- kolejność etapów pipeline jest zgodna z modelem RBAC

## Uwagi

- W projekcie wykorzystano narzędzia AI (GitHub Copilot i Claude Code) do wsparcia analizy, przygotowania wersji roboczych i dokumentacji. Decyzje architektoniczne, walidację oraz finalną implementację wykonał autor.
