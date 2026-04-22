import pandas as pd

setattr(pd, "Int64Index", pd.Index)
setattr(pd, "Float64Index", pd.Index)

from sklearn.ensemble import RandomForestClassifier
from catboost import CatBoostClassifier
from lightgbm import LGBMClassifier
from sklearn.metrics import classification_report, accuracy_score,average_precision_score, precision_recall_curve
from xgboost import XGBClassifier
from sklearn.metrics import log_loss
from sklearn.model_selection import GroupKFold
import numpy as np

    
import Graph
import matplotlib.pyplot as plt
from sklearn.experimental import enable_halving_search_cv
from sklearn.model_selection import HalvingRandomSearchCV
from scipy.stats import randint, uniform

def get_feature_importance(model, feature_names):
    #Feature importance for single-output classifiers
    importance_df = pd.DataFrame({
        'feature': feature_names,
        'importance': model.feature_importances_
    }).sort_values('importance', ascending=False)
    return importance_df.head(10)

def get_best_model(estimator, param_dist, X_train, Y_train, groups, scoring='average_precision'):
    #Helper to run HalvingRandomSearchCV and return the best fitted model.
    cv = GroupKFold(n_splits=5)
    search = HalvingRandomSearchCV(
        estimator,
        param_distributions=param_dist,
        min_resources=3000,
        scoring=scoring,
        cv=cv,
        factor=3,
        random_state=42,
        n_jobs=-1,
        verbose=1,
        error_score=0
    )
    search.fit(X_train, Y_train, groups=groups)  
    print(f"\n  Best params: {search.best_params_}")
    print(f"  Best CV {scoring}: {search.best_score_:.4f}")
    return search.best_estimator_


def evaluate_model(model, name, X_train, Y_train, X_test, Y_test, target_names, feature_names, threshold=0.5):
    probs = model.predict_proba(X_test)
    test_probs_thresh = probs[:, 1]

    print(f"  target_names: {target_names}")
    print(f"  Unique Y_test values: {np.unique(Y_test)}")
    print(f"  Max IMPROVED prob: {test_probs_thresh.max():.4f}")
    print(f"  Mean IMPROVED prob: {test_probs_thresh.mean():.4f}")
    print(f"  % above 0.3:  {(test_probs_thresh >= 0.3).mean():.4f}")
    print(f"  % above 0.1:  {(test_probs_thresh >= 0.1).mean():.4f}")
    print(f"  % above 0.05: {(test_probs_thresh >= 0.05).mean():.4f}")
    print(model.classes_)

    # Numeric versions for everything
    Y_test_numeric  = np.array(Y_test).astype(int)
    Y_train_numeric = np.array(Y_train).astype(int)

    # Threshold based prediction — stays numeric
    preds = (test_probs_thresh >= threshold).astype(int)

    unique, counts = np.unique(preds, return_counts=True)
    mapped = {target_names[k]: v for k, v in zip(unique, counts)}
    print(f"  Prediction distribution: {mapped}")
    print(f"\n--- {name} Classification Report ---")
    print(f"   Score_Threshold: {threshold}")
    print(classification_report(Y_test_numeric, preds, target_names=target_names, zero_division=0))

    print(f"  Accuracy: {accuracy_score(Y_test_numeric, preds):.4f}")
    print(f"  Log Loss: {log_loss(Y_test_numeric, probs):.4f}")

    train_probs  = model.predict_proba(X_train)[:, 1]
    test_probs   = probs[:, 1]
    train_pr_auc = average_precision_score(Y_train_numeric, train_probs)
    test_pr_auc  = average_precision_score(Y_test_numeric, test_probs)
    print(f"  Train PR-AUC: {train_pr_auc:.3f}")
    print(f"  Test  PR-AUC: {test_pr_auc:.3f}")

    precision, recall, _ = precision_recall_curve(Y_test_numeric, test_probs)
    plt.figure(figsize=(8, 5))
    plt.plot(recall, precision)
    plt.axhline(y=Y_test_numeric.mean(), color='k', linestyle='--', label=f"Random baseline ({Y_test_numeric.mean():.2f})")
    plt.xlabel("Recall")
    plt.ylabel("Precision")
    plt.title(f"{name} - Precision-Recall Curve")
    plt.legend()
    plt.savefig(f"pr_curve_{name.replace(' ', '_')}.png", bbox_inches='tight', dpi=150)
    plt.close()

    importance = get_feature_importance(model, feature_names)
    print(f"\n--- {name} Feature Importance ---")
    print(importance)
    Graph.shap_plots(model, X_test, feature_names, target_names, name.lower().replace(" ", "_"))
    

def randomforest_model(X_train, Y_train, X_test, Y_test, target_names, feature_names, groups, threshold=0.3):
    param_dist = {
        "n_estimators":      randint(100, 800),
        "max_depth":         [None, 5, 10, 15, 20],
        "min_samples_split": randint(2, 20),
        "min_samples_leaf":  randint(1, 20),
        "max_features":      ["sqrt", "log2", 0.3, 0.5],
        "class_weight":      ["balanced", "balanced_subsample"],
    }
    base = RandomForestClassifier(random_state=42)
    model = get_best_model(base, param_dist, X_train, Y_train, groups=groups)
    evaluate_model(model, "Random Forest", X_train, Y_train, X_test, Y_test, target_names, feature_names, threshold=threshold)


def catboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names, groups, threshold=0.3):
    param_dist = {
        "iterations":    randint(200, 800),
        "learning_rate": uniform(0.01, 0.29),
        "depth":         randint(3, 10),
        "l2_leaf_reg":   uniform(1, 10),
        "subsample":     uniform(0.6, 0.4),
        "colsample_bylevel": uniform(0.6, 0.4),
        "auto_class_weights": ["Balanced", "SqrtBalanced"],  # key for your imbalance
    }
    base = CatBoostClassifier(random_seed=42, verbose=0)
    model = get_best_model(base, param_dist, X_train, Y_train, groups = groups)
    evaluate_model(model, "CatBoost", X_train, Y_train, X_test, Y_test, target_names, feature_names, threshold=threshold)


def lightgbm_model(X_train, Y_train, X_test, Y_test, target_names, feature_names, groups, threshold=0.3):
    param_dist = {
        "n_estimators":      randint(100, 800),
        "learning_rate":     uniform(0.01, 0.29),
        "num_leaves":        randint(20, 200),
        "max_depth":         randint(3, 12),
        "min_child_samples": randint(10, 100),
        "subsample":         uniform(0.5, 0.5),
        "colsample_bytree":  uniform(0.5, 0.5),
        "reg_alpha":         uniform(0, 5),
        "reg_lambda":        uniform(0, 5),
        "scale_pos_weight":  uniform(8, 7),   # samples between 8–15 for your ~12.5x imbalance
    }
    base = LGBMClassifier(random_state=42, verbose=-1)
    model = get_best_model(base, param_dist, X_train, Y_train, groups=groups)
    evaluate_model(model, "LightGBM", X_train, Y_train, X_test, Y_test, target_names, feature_names, threshold=threshold)


def xgboost_model(X_train, Y_train, X_test, Y_test, target_names, feature_names, groups, threshold=0.3):
    param_dist = {
        "n_estimators":     randint(100, 800),
        "learning_rate":    uniform(0.01, 0.29),
        "max_depth":        randint(3, 10),
        "subsample":        uniform(0.5, 0.5),
        "colsample_bytree": uniform(0.5, 0.5),
        "gamma":            uniform(0, 5),
        "reg_alpha":        uniform(0, 5),
        "reg_lambda":       uniform(0, 5),
        "scale_pos_weight": uniform(8, 7),
    }
    base = XGBClassifier(random_state=42, eval_metric='mlogloss', verbosity=0, tree_method='hist')
    
    # Convert to numpy to avoid pandas 2.0 / XGBoost 1.2.1 versions incompatibility
    X_train_np = X_train.values if hasattr(X_train, 'values') else X_train
    Y_train_np = Y_train.values if hasattr(Y_train, 'values') else Y_train
    X_test_np  = X_test.values  if hasattr(X_test,  'values') else X_test
    Y_test_np  = Y_test.values  if hasattr(Y_test,  'values') else Y_test

    model = get_best_model(base, param_dist, X_train_np, Y_train_np, groups=groups)
    evaluate_model(model, "XGBoost", X_train_np, Y_train_np, X_test_np, Y_test_np, target_names, feature_names, threshold=threshold)